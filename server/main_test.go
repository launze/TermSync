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

func TestMatchesReleasePlatformAcceptsDirectDesktopOS(t *testing.T) {
	tests := []struct {
		name     string
		platform string
		want     bool
	}{
		{name: "termsync-desktop-windows-x64-v0.1.14-setup.exe", platform: "windows", want: true},
		{name: "termsync-desktop-windows-x64-v0.1.14.msi", platform: "windows", want: true},
		{name: "termsync-desktop-macos-arm64-v0.1.14.dmg", platform: "macos", want: true},
		{name: "termsync-desktop-linux-x64-v0.1.14.AppImage", platform: "linux", want: true},
		{name: "termsync-desktop-linux-x64-v0.1.14.deb", platform: "windows", want: false},
	}
	for _, tt := range tests {
		t.Run(tt.platform+"/"+tt.name, func(t *testing.T) {
			if got := matchesReleasePlatform(tt.name, tt.platform); got != tt.want {
				t.Fatalf("matchesReleasePlatform(%q, %q) = %v, want %v", tt.name, tt.platform, got, tt.want)
			}
		})
	}
}

func TestLatestDownloadsKeepsNewestPerPlatform(t *testing.T) {
	items := []downloadItem{
		{Name: "termsync-desktop-windows-x64-v0.1.10-setup.exe", Platform: "Windows Setup"},
		{Name: "termsync-desktop-windows-x64-v0.1.12-setup.exe", Platform: "Windows Setup"},
		{Name: "termsync-desktop-windows-x64-v0.1.11.msi", Platform: "Windows MSI"},
		{Name: "termsync-desktop-windows-x64-v0.1.12.msi", Platform: "Windows MSI"},
		{Name: "termsync-android-release-v0.1.10.apk", Platform: "Android"},
	}

	latest := latestDownloads(items)
	if len(latest) != 3 {
		t.Fatalf("len(latestDownloads) = %d, want 3", len(latest))
	}
	wantByPlatform := map[string]string{
		"Windows Setup": "termsync-desktop-windows-x64-v0.1.12-setup.exe",
		"Windows MSI":   "termsync-desktop-windows-x64-v0.1.12.msi",
		"Android":       "termsync-android-release-v0.1.10.apk",
	}
	for _, item := range latest {
		if want := wantByPlatform[item.Platform]; item.Name != want {
			t.Fatalf("latest for %q = %q, want %q", item.Platform, item.Name, want)
		}
		delete(wantByPlatform, item.Platform)
	}
	if len(wantByPlatform) != 0 {
		t.Fatalf("missing latest downloads for platforms: %v", wantByPlatform)
	}
}
