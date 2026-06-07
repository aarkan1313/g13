//! M2.4c: bounded LRU cache of baked RegionMacros, keyed by (rx,rz). Deterministic
//! rebuild (MacroBake) makes eviction safe — purely a speed cache, never truth.
//! Pure data structure; the scheduler (step 3) owns threading.

use std::collections::HashMap;
use std::collections::VecDeque;

use crate::macro_cache::RegionMacro;

pub struct RegionCache {
    cap: usize,
    map: HashMap<(i32, i32), RegionMacro>,
    recency: VecDeque<(i32, i32)>, // front = LRU, back = MRU
}

impl RegionCache {
    pub fn new(cap: usize) -> Self {
        Self { cap: cap.max(1), map: HashMap::new(), recency: VecDeque::new() }
    }

    pub fn len(&self) -> usize { self.map.len() }
    pub fn is_empty(&self) -> bool { self.map.is_empty() }
    pub fn contains(&self, rx: i32, rz: i32) -> bool { self.map.contains_key(&(rx, rz)) }

    /// Get + mark most-recently-used.
    pub fn get(&mut self, rx: i32, rz: i32) -> Option<&RegionMacro> {
        let key = (rx, rz);
        if self.map.contains_key(&key) {
            self.touch(key);
            self.map.get(&key)
        } else {
            None
        }
    }

    /// Insert (or replace), mark MRU, evict LRU if over cap.
    pub fn insert(&mut self, region: RegionMacro) {
        let key = (region.region_x, region.region_z);
        self.map.insert(key, region);
        self.touch(key);
        while self.map.len() > self.cap {
            if let Some(lru) = self.recency.pop_front() {
                // pop_front may name a stale key already re-touched; only evict if it
                // is still the front-most occurrence (i.e. not present later).
                if !self.recency.contains(&lru) {
                    self.map.remove(&lru);
                }
            } else {
                break;
            }
        }
    }

    fn touch(&mut self, key: (i32, i32)) {
        self.recency.retain(|k| *k != key);
        self.recency.push_back(key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::macro_cache::RegionMacro;

    fn rm(rx: i32, rz: i32) -> RegionMacro { RegionMacro::zeroed(rx, rz, 2) }

    #[test]
    fn insert_and_get() {
        let mut c = RegionCache::new(4);
        assert!(c.get(0, 0).is_none());
        c.insert(rm(0, 0));
        assert!(c.contains(0, 0));
        assert_eq!(c.get(0, 0).unwrap().region_x, 0);
        assert_eq!(c.len(), 1);
    }

    #[test]
    fn bounded_evicts_lru() {
        let mut c = RegionCache::new(2);
        c.insert(rm(0, 0));
        c.insert(rm(1, 0));
        let _ = c.get(0, 0);          // touch (0,0) -> now (1,0) is LRU
        c.insert(rm(2, 0));           // over cap -> evict LRU = (1,0)
        assert!(c.contains(0, 0), "recently-used kept");
        assert!(c.contains(2, 0), "newest kept");
        assert!(!c.contains(1, 0), "LRU evicted");
        assert_eq!(c.len(), 2);
    }

    #[test]
    fn reinsert_updates_recency_not_size() {
        let mut c = RegionCache::new(2);
        c.insert(rm(0, 0));
        c.insert(rm(0, 0));           // same key again
        assert_eq!(c.len(), 1);
    }
}
