//go:build unix

package launcher

import "os"

// syncDir fsyncs a directory so a rename into it is durable across a crash. On
// Unix, opening the directory and calling Sync() issues that fsync; it is what
// makes atomicWriteFile's rename survive power loss.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
