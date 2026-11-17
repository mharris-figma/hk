#!/usr/bin/env bats

setup() {
    load 'test_helper/common_setup'
    _common_setup
}

teardown() {
    _common_teardown
}

write_config() {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
fail_fast = false
hooks {
    ["check"] {
        steps {
            ["pass"] {
                check = "echo passed"
                output_summary = "combined"
            }
            ["fail"] {
                check = "echo diagnostic >&2; exit 1"
                output_summary = "combined"
            }
        }
    }
}
EOF
    touch input.txt
    git add .
    git commit -m init
}

@test "JUnit XML export works independently of the human output format" {
    write_config

    run hk check --all --junit-xml junit.xml
    assert_failure
    assert_file_exists junit.xml
    run python3 -c "import xml.etree.ElementTree as ET; ET.parse('junit.xml')"
    assert_success
    run bash -c "grep -F '<testsuite name=\"check\" tests=\"2\" failures=\"1\" errors=\"0\" skipped=\"0\"' junit.xml"
    assert_success
    run bash -c "grep -F '<testcase name=\"fail\"' junit.xml"
    assert_success
    run bash -c "grep -F '<failure message=\"step failed\">diagnostic' junit.xml"
    assert_success
}

@test "JUnit write errors are reported even when the hook also fails" {
    write_config

    run bash -c "hk --format json check --all --junit-xml hk.pkl/junit.xml 2>machine-errors.log"
    assert_failure
    run jq -e '.schema_version == 1 and .status == "failed"' <<<"$output"
    assert_success
    run grep -F "failed to emit result after hook also failed" machine-errors.log
    assert_success
    assert_file_not_exists hk.pkl/junit.xml
}

@test "skipped steps are reported as JUnit skipped test cases" {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
hooks {
    ["check"] {
        steps {
            ["files"] {
                check = "true"
                glob = List("*.rs")
            }
        }
    }
}
EOF
    git add .
    git commit -m init

    run hk check --all --junit-xml junit.xml
    assert_success
    run python3 -c "import xml.etree.ElementTree as ET; ET.parse('junit.xml')"
    assert_success
    run bash -c "grep -F '<skipped message=\"skipped: no files to process\"/>' junit.xml"
    assert_success
}

@test "early no-op runs still write a JUnit report" {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
hooks {
    ["check"] { steps {} }
}
EOF
    git add .
    git commit -m init

    run hk check --all --junit-xml junit.xml
    assert_success
    assert_file_exists junit.xml
    run python3 -c "import xml.etree.ElementTree as ET; ET.parse('junit.xml')"
    assert_success
    run bash -c "grep -F '<testsuite name=\"check\" tests=\"0\" failures=\"0\" errors=\"0\" skipped=\"0\"' junit.xml"
    assert_success
}

@test "setup failures produce a synthetic JUnit error test case" {
    write_config
    mv .git .git.saved

    run hk check --all --junit-xml junit.xml
    assert_failure
    assert_file_exists junit.xml
    run python3 -c "import xml.etree.ElementTree as ET; ET.parse('junit.xml')"
    assert_success
    run bash -c "grep -F '<testsuite name=\"check\" tests=\"1\" failures=\"0\" errors=\"1\"' junit.xml"
    assert_success
    run bash -c "grep -F '<testcase name=\"check\" classname=\"hk\"' junit.xml"
    assert_success
}

@test "JSON and JUnit report content changes independently of step success" {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
fail_fast = false
hooks {
    ["fix"] {
        steps {
            ["format"] {
                glob = "format.txt"
                fix = "printf formatted > {{files}}"
            }
            ["unchanged"] {
                glob = "unchanged.txt"
                fix = "touch {{files}}"
            }
            ["partial"] {
                glob = "partial.txt"
                fix = """
                    printf partial > {{files}}
                    exit 1
                    """
            }
            ["unlocked"] {
                glob = "unlocked.txt"
                stomp = true
                fix = "printf changed > {{files}}"
            }
        }
    }
}
EOF
    touch format.txt unchanged.txt partial.txt unlocked.txt
    git add .
    git commit -m init
    echo 'developer edit' > unchanged.txt

    run bash -c "hk fix --all --format json --junit-xml junit.xml 2>machine-errors.log"
    assert_failure
    run jq -e '
        [.steps[] | {key: .name, value: [.status, .files_changed]}] | from_entries
        | . == {format: ["passed", true], unchanged: ["passed", false],
                partial: ["failed", true], unlocked: ["passed", null]}
    ' <<<"$output"
    assert_success
    run python3 - <<'PY'
import xml.etree.ElementTree as ET
cases = {case.get('name'): case for case in ET.parse('junit.xml').iter('testcase')}
for name, expected in [('format', 'true'), ('unchanged', 'false'), ('partial', 'true')]:
    assert cases[name].find('./properties/property[@name="files_changed"]').get('value') == expected
assert cases['format'].find('failure') is None
assert cases['unchanged'].find('failure') is None
assert cases['partial'].find('failure') is not None
assert cases['unlocked'].find('./properties/property[@name="files_changed"]') is None
PY
    assert_success
}

@test "file changes combine batches without attributing a preceding step's edits" {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
hooks {
    ["fix"] {
        steps {
            ["format"] {
                glob = "*.txt"
                batch = true
                batch_min_files = 1
                fix = """
                    for file in {{files}}
                    do
                        if [ "\$file" = a.txt ]
                        then
                            printf formatted > "\$file"
                        fi
                    done
                    """
            }
            ["unchanged"] {
                depends = List("format")
                glob = "*.txt"
                fix = "touch {{files}}"
            }
        }
    }
}
EOF
    touch a.txt b.txt
    git add .
    git commit -m init

    run bash -c "hk fix --all --format json 2>machine-errors.log"
    assert_success
    run jq -e '[.steps[] | {key: .name, value: .files_changed}] | from_entries
        | . == {format: true, unchanged: false}' <<<"$output"
    assert_success
}

@test "applied patches report changed contents including newly created files" {
    cat <<EOF > hk.pkl
amends "$PKL_PATH/Config.pkl"
hooks {
    ["fix"] {
        steps {
            ["create"] {
                glob = "seed.txt"
                check_diff = """
                    printf '%s\\n' '--- /dev/null' '+++ generated.txt' '@@ -0,0 +1 @@' '+generated'
                    exit 1
                    """
                fix = "exit 99"
                check_after_diff = true
                check = "true"
            }
            ["same"] {
                glob = "same.txt"
                check_diff = new CommandSpec {
                    effect = "read"
                    command = """
                        printf '%s\\n' '--- same.txt' '+++ same.txt' '@@ -1 +1 @@' '-same' '+same'
                        exit 1
                        """
                }
                fix = "exit 99"
            }
        }
    }
}
EOF
    touch seed.txt
    echo same > same.txt
    git add .
    git commit -m init

    run hk fix --all --junit-xml junit.xml
    assert_success
    assert_file_contains generated.txt generated
    run python3 - <<'PY'
import xml.etree.ElementTree as ET
cases = {case.get('name'): case for case in ET.parse('junit.xml').iter('testcase')}
assert cases['create'].find('./properties/property[@name="files_changed"]').get('value') == 'true'
assert cases['same'].find('./properties/property[@name="files_changed"]').get('value') == 'false'
assert all(case.find('failure') is None for case in cases.values())
PY
    assert_success
}
