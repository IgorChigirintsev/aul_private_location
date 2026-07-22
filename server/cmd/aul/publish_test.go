package main

import (
	"testing"

	"github.com/aul-app/aul/server/internal/store"
)

// deref returns the pointed-to string or a sentinel for nil, so tests can
// compare optional *string fields concisely.
func deref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}

func TestParsePublishFlags(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		wantErr bool
		// checks run only when no error is expected.
		check func(t *testing.T, p store.UpsertAppVersionParams)
	}{
		{
			name: "valid android row",
			args: []string{
				"--platform", "android",
				"--version-code", "42",
				"--version-name", "1.4.2",
				"--apk-url", "https://dl.example.com/aul-42.apk",
				"--sha256", "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
				"--changelog", "fixes",
				"--min-supported", "30",
			},
			check: func(t *testing.T, p store.UpsertAppVersionParams) {
				if p.Platform != "android" {
					t.Errorf("Platform = %q, want android", p.Platform)
				}
				if p.VersionCode != 42 {
					t.Errorf("VersionCode = %d, want 42", p.VersionCode)
				}
				if p.VersionName != "1.4.2" {
					t.Errorf("VersionName = %q, want 1.4.2", p.VersionName)
				}
				if got := deref(p.ApkUrl); got != "https://dl.example.com/aul-42.apk" {
					t.Errorf("ApkUrl = %q", got)
				}
				if got := deref(p.Sha256); got != "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789" {
					t.Errorf("Sha256 = %q", got)
				}
				if got := deref(p.Changelog); got != "fixes" {
					t.Errorf("Changelog = %q, want fixes", got)
				}
				if p.MinSupported != 30 {
					t.Errorf("MinSupported = %d, want 30", p.MinSupported)
				}
			},
		},
		{
			name: "valid minimal row, optional fields become nil",
			args: []string{
				"--platform", "ios",
				"--version-code", "1",
				"--version-name", "1.0.0",
			},
			check: func(t *testing.T, p store.UpsertAppVersionParams) {
				if p.ApkUrl != nil {
					t.Errorf("ApkUrl = %q, want nil", *p.ApkUrl)
				}
				if p.Sha256 != nil {
					t.Errorf("Sha256 = %q, want nil", *p.Sha256)
				}
				if p.Changelog != nil {
					t.Errorf("Changelog = %q, want nil", *p.Changelog)
				}
				if p.MinSupported != 0 {
					t.Errorf("MinSupported = %d, want 0", p.MinSupported)
				}
			},
		},
		{
			name:    "missing platform",
			args:    []string{"--version-code", "1", "--version-name", "1.0.0"},
			wantErr: true,
		},
		{
			name:    "bad platform windows",
			args:    []string{"--platform", "windows", "--version-code", "1", "--version-name", "1.0.0"},
			wantErr: true,
		},
		{
			name:    "missing version-name",
			args:    []string{"--platform", "android", "--version-code", "1"},
			wantErr: true,
		},
		{
			name:    "version-code zero",
			args:    []string{"--platform", "android", "--version-code", "0", "--version-name", "1.0.0"},
			wantErr: true,
		},
		{
			name: "sha256 wrong length",
			args: []string{
				"--platform", "android", "--version-code", "1", "--version-name", "1.0.0",
				"--sha256", "abcd",
			},
			wantErr: true,
		},
		{
			name: "sha256 uppercase is lowercased",
			args: []string{
				"--platform", "android", "--version-code", "1", "--version-name", "1.0.0",
				"--apk-url", "https://dl.example.com/a.apk",
				"--sha256", "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789",
			},
			check: func(t *testing.T, p store.UpsertAppVersionParams) {
				want := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
				if got := deref(p.Sha256); got != want {
					t.Errorf("Sha256 = %q, want lowercased %q", got, want)
				}
			},
		},
		{
			name: "apk-url without sha256",
			args: []string{
				"--platform", "android", "--version-code", "1", "--version-name", "1.0.0",
				"--apk-url", "https://dl.example.com/a.apk",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parsePublishFlags(tt.args)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got params %+v", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.check != nil {
				tt.check(t, got)
			}
		})
	}
}
