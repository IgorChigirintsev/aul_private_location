package httpapi

import (
	"io"
	"io/fs"
	"mime"
	"net/http"
	"path"
	"path/filepath"
	"strings"
)

// StaticConfig configures asset serving.
type StaticConfig struct {
	WebFS  fs.FS  // embedded built web app (index.html at root)
	DevDir string // if set, serve web assets from this directory instead (dev)
	APKDir string // if set, serve APKs from here under /download/
}

// NewStaticHandler serves the SPA web app with history-API fallback plus APK
// downloads. Unknown non-asset paths fall back to index.html so client-side
// routes work; API paths are handled before this via chi's NotFound wiring.
func NewStaticHandler(cfg StaticConfig) http.Handler {
	webFS := cfg.WebFS
	if cfg.DevDir != "" {
		webFS = osDirFS(cfg.DevDir)
	}
	return &staticHandler{web: webFS, apkDir: cfg.APKDir}
}

type staticHandler struct {
	web    fs.FS
	apkDir string
}

func (h *staticHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	upath := path.Clean("/" + strings.TrimPrefix(r.URL.Path, "/"))

	// APK downloads.
	if h.apkDir != "" && strings.HasPrefix(upath, "/download/") {
		h.serveAPK(w, r, strings.TrimPrefix(upath, "/download/"))
		return
	}

	if h.web == nil {
		http.NotFound(w, r)
		return
	}

	// Try the exact file first.
	if serveFSFile(w, r, h.web, strings.TrimPrefix(upath, "/"), false) {
		return
	}
	// Looks like a static asset (has extension) but missing → 404.
	if ext := path.Ext(upath); ext != "" && upath != "/" {
		http.NotFound(w, r)
		return
	}
	// SPA fallback to index.html.
	if !serveFSFile(w, r, h.web, "index.html", true) {
		http.NotFound(w, r)
	}
}

func (h *staticHandler) serveAPK(w http.ResponseWriter, r *http.Request, name string) {
	// Prevent path traversal; only a bare filename is allowed.
	if name == "" || strings.ContainsAny(name, "/\\") || strings.Contains(name, "..") {
		http.NotFound(w, r)
		return
	}
	full := filepath.Join(h.apkDir, name)
	f, err := http.Dir(h.apkDir).Open(name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil || info.IsDir() {
		http.NotFound(w, r)
		return
	}
	if strings.HasSuffix(name, ".apk") {
		w.Header().Set("Content-Type", "application/vnd.android.package-archive")
		w.Header().Set("Content-Disposition", "attachment; filename=\""+filepath.Base(full)+"\"")
	}
	http.ServeContent(w, r, name, info.ModTime(), f)
}

// serveFSFile serves name from fsys. Returns false if the file is absent or a
// directory. noCache=false sets long cache headers for hashed assets.
func serveFSFile(w http.ResponseWriter, r *http.Request, fsys fs.FS, name string, isFallback bool) bool {
	if name == "" {
		name = "index.html"
	}
	f, err := fsys.Open(name)
	if err != nil {
		return false
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil || info.IsDir() {
		return false
	}
	ctype := mime.TypeByExtension(path.Ext(name))
	if ctype == "" {
		ctype = "application/octet-stream"
	}
	w.Header().Set("Content-Type", ctype)
	if isFallback || name == "index.html" || strings.HasSuffix(name, ".html") {
		w.Header().Set("Cache-Control", "no-cache")
	} else {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	}
	if rs, ok := f.(io.ReadSeeker); ok {
		http.ServeContent(w, r, name, info.ModTime(), rs)
	} else {
		w.WriteHeader(http.StatusOK)
		_, _ = io.Copy(w, f)
	}
	return true
}

// osDirFS adapts a filesystem directory to fs.FS for dev serving.
func osDirFS(dir string) fs.FS { return dirFS(dir) }

type dirFS string

func (d dirFS) Open(name string) (fs.File, error) {
	if name == "" {
		name = "index.html"
	}
	return http.Dir(string(d)).Open("/" + name)
}
