use std::{
    collections::{HashMap, hash_map::DefaultHasher},
    hash::{Hash, Hasher},
    io,
    path::{Path, PathBuf},
    sync::Mutex,
};

#[derive(Default)]
pub struct FileChanges {
    pub enabled: bool,
    observations: Mutex<HashMap<String, Vec<Option<bool>>>>,
}

impl FileChanges {
    /// Keep the command's file locks held from this snapshot through `finish`.
    pub fn start<'a>(
        &'a self,
        step: &'a str,
        files: Option<&[PathBuf]>,
    ) -> Option<Observation<'a>> {
        if !self.enabled {
            return None;
        }
        let index = {
            let mut observations = self.observations.lock().unwrap();
            let observations = observations.entry(step.to_owned()).or_default();
            // An interrupted command leaves its observation unknown.
            observations.push(None);
            observations.len() - 1
        };
        let before = files.filter(|files| !files.is_empty()).and_then(|files| {
            files
                .iter()
                .map(|path| Ok((path.clone(), content_hash(path)?)))
                .collect::<io::Result<Vec<_>>>()
                .ok()
        });
        Some(Observation {
            recorder: self,
            step,
            index,
            before,
        })
    }

    pub fn record(&self, step: &str, changed: Option<bool>) {
        if self.enabled {
            self.observations
                .lock()
                .unwrap()
                .entry(step.to_owned())
                .or_default()
                .push(changed);
        }
    }

    pub fn get(&self, step: &str) -> Option<bool> {
        let observations = self.observations.lock().unwrap();
        let observations = observations.get(step)?;
        if observations.contains(&Some(true)) {
            Some(true)
        } else if observations.iter().all(|changed| *changed == Some(false)) {
            Some(false)
        } else {
            None
        }
    }
}

pub struct Observation<'a> {
    recorder: &'a FileChanges,
    step: &'a str,
    index: usize,
    before: Option<Vec<(PathBuf, Option<u64>)>>,
}

impl Observation<'_> {
    /// Compare before the caller releases the command's file locks.
    pub fn finish(self) {
        let changed = self.before.and_then(|before| {
            let mut unknown = false;
            for (path, hash) in before {
                match content_hash(&path) {
                    Ok(after) if after != hash => return Some(true),
                    Ok(_) => {}
                    Err(_) => unknown = true,
                }
            }
            (!unknown).then_some(false)
        });
        self.recorder
            .observations
            .lock()
            .unwrap()
            .get_mut(self.step)
            .unwrap()[self.index] = changed;
    }
}

fn content_hash(path: &Path) -> io::Result<Option<u64>> {
    match std::fs::read(path) {
        Ok(content) => {
            let mut hasher = DefaultHasher::new();
            content.hash(&mut hasher);
            Ok(Some(hasher.finish()))
        }
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observations_compare_contents_and_existence() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("input");
        let files = vec![path.clone()];
        let recorder = FileChanges {
            enabled: true,
            ..Default::default()
        };

        let creation = recorder.start("create", Some(&files)).unwrap();
        std::fs::write(&path, "original").unwrap();
        creation.finish();
        assert_eq!(recorder.get("create"), Some(true));

        let same = recorder.start("same", Some(&files)).unwrap();
        std::fs::write(&path, "original").unwrap();
        same.finish();
        assert_eq!(recorder.get("same"), Some(false));

        let deletion = recorder.start("delete", Some(&files)).unwrap();
        std::fs::remove_file(&path).unwrap();
        deletion.finish();
        assert_eq!(recorder.get("delete"), Some(true));
    }

    #[test]
    fn incomplete_observations_do_not_hide_changes_or_imply_no_changes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("input");
        std::fs::write(&path, "original").unwrap();
        let files = vec![path];
        let recorder = FileChanges {
            enabled: true,
            ..Default::default()
        };
        let interrupted = recorder.start("format", Some(&files)).unwrap();
        recorder.start("format", Some(&files)).unwrap().finish();
        drop(interrupted);
        assert_eq!(recorder.get("format"), None);
        recorder.record("format", Some(true));
        recorder.record("format", Some(false));
        assert_eq!(recorder.get("format"), Some(true));

        let unreadable = vec![dir.path().to_owned()];
        recorder
            .start("unreadable", Some(&unreadable))
            .unwrap()
            .finish();
        assert_eq!(recorder.get("unreadable"), None);
    }
}
