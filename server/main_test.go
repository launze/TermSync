package main

import "testing"

func TestMatchesReleaseBuildTypeAndroid(t *testing.T) {
	tests := []struct {
		name      string
		buildType string
		want      bool
	}{
		{name: "termsync-android-release-v0.1.6.apk", buildType: "release", want: true},
		{name: "termsync-android-release-v0.1.6.apk", buildType: "debug", want: false},
		{name: "termsync-android-debug-v0.1.6-debug.apk", buildType: "debug", want: true},
		{name: "termsync-android-debug-v0.1.6-debug.apk", buildType: "release", want: false},
		{name: "termsync-android-v0.1.6.apk", buildType: "release", want: true},
		{name: "termsync-android-v0.1.6.apk", buildType: "debug", want: false},
	}

	for _, tt := range tests {
		got := matchesReleaseBuildType(tt.name, "android", tt.buildType)
		if got != tt.want {
			t.Fatalf("matchesReleaseBuildType(%q, android, %q) = %v, want %v", tt.name, tt.buildType, got, tt.want)
		}
	}
}

func TestMatchesReleaseBuildTypeNonAndroid(t *testing.T) {
	if !matchesReleaseBuildType("termsync-desktop-windows-x64-v0.1.6-setup.exe", "desktop", "debug") {
		t.Fatal("non-Android release filtering should ignore build type")
	}
}

func TestNormalizeReleaseBuildType(t *testing.T) {
	if got := normalizeReleaseBuildType("debug"); got != "debug" {
		t.Fatalf("normalizeReleaseBuildType(debug) = %q", got)
	}
	if got := normalizeReleaseBuildType(""); got != "release" {
		t.Fatalf("normalizeReleaseBuildType(empty) = %q", got)
	}
	if got := normalizeReleaseBuildType("anything"); got != "release" {
		t.Fatalf("normalizeReleaseBuildType(anything) = %q", got)
	}
}

func TestMatchesReleaseOSDesktop(t *testing.T) {
	if !matchesReleaseOS("termsync-desktop-windows-x64-v0.1.9-setup.exe", "desktop", "windows") {
		t.Fatal("windows setup should match windows desktop release")
	}
	if matchesReleaseOS("termsync-desktop-linux-arm64-v0.1.9.AppImage", "desktop", "windows") {
		t.Fatal("linux AppImage must not match windows desktop release")
	}
	if !matchesReleaseOS("termsync-desktop-linux-arm64-v0.1.9.AppImage", "desktop", "") {
		t.Fatal("empty target OS should preserve legacy all-desktop matching")
	}
}
