//go:build !unix

package launcher

// syncDir is a no-op off Unix: Windows has no directory-fsync equivalent, and
// os.Open on a directory there does not yield a syncable handle. Keeping the
// signature identical lets atomicWriteFile stay a single codepath.
func syncDir(string) error { return nil }
