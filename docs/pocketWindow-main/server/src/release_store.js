const fs = require('fs');
const path = require('path');

function parsePositiveInt(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 0;
  return Math.max(0, Math.floor(parsed));
}

function normalizeReleasePlatform(value) {
  const normalized = String(value || '').trim().toLowerCase();
  if (normalized === 'android' || normalized === 'windows') {
    return normalized;
  }
  return '';
}

function normalizeChannel(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return normalized || 'stable';
}

function sanitizeReleaseRecord(input, platform, safeFilename) {
  const version = String(input?.version || '').trim();
  const fileName = safeFilename(input?.file_name || input?.fileName || '');
  const fileToken = String(input?.file_token || input?.fileToken || '').trim();
  if (!platform || !version || !fileName || !fileToken) {
    return null;
  }
  return {
    platform,
    version,
    build: parsePositiveInt(input?.build),
    channel: normalizeChannel(input?.channel),
    title: String(input?.title || '').trim(),
    notes: String(input?.notes || '').trim(),
    fileName,
    fileToken,
    fileSize: parsePositiveInt(input?.file_size || input?.fileSize),
    sha256: String(input?.sha256 || '').trim().toLowerCase(),
    mimeType: String(input?.mime_type || input?.mimeType || 'application/octet-stream').trim(),
    forceUpdate: input?.force_update === true || String(input?.force_update || '').trim() === 'true',
    minSupportedVersion: String(input?.min_supported_version || input?.minSupportedVersion || '').trim(),
    createdAt: parsePositiveInt(input?.created_at || input?.createdAt) || Date.now(),
  };
}

function sanitizeReleaseForClient(release, req) {
  if (!release) return null;
  return {
    platform: release.platform,
    version: release.version,
    build: release.build,
    channel: release.channel,
    title: release.title,
    notes: release.notes,
    file_name: release.fileName,
    file_size: release.fileSize,
    sha256: release.sha256,
    mime_type: release.mimeType,
    force_update: release.forceUpdate,
    min_supported_version: release.minSupportedVersion,
    created_at: release.createdAt,
    download_url: `/api/releases/download/${encodeURIComponent(release.platform)}/${encodeURIComponent(release.fileToken)}`,
    source_url: `${req.protocol}://${req.get('host')}/api/releases/download/${encodeURIComponent(release.platform)}/${encodeURIComponent(release.fileToken)}`,
  };
}

function createReleaseStore({
  releasesDir,
  stateFile,
  ensureDataDir,
  safeFilename,
}) {
  const releasesByPlatform = new Map();

  function releaseFilePath(fileToken, fileName) {
    return path.join(releasesDir, `${fileToken}-${fileName}`);
  }

  function serialize() {
    return {
      releases: Array.from(releasesByPlatform.entries())
        .map(([platform, release]) => ({
          platform,
          ...release,
        }))
        .sort((left, right) => String(left.platform).localeCompare(String(right.platform))),
    };
  }

  function persist() {
    try {
      ensureDataDir();
      fs.writeFileSync(stateFile, JSON.stringify(serialize(), null, 2), 'utf8');
    } catch (error) {
      console.error('[RELEASES] Persist failed:', error && error.message ? error.message : String(error));
    }
  }

  function load() {
    try {
      ensureDataDir();
      if (!fs.existsSync(stateFile)) {
        return;
      }
      const raw = fs.readFileSync(stateFile, 'utf8');
      if (!raw.trim()) {
        return;
      }
      const parsed = JSON.parse(raw);
      const releases = Array.isArray(parsed?.releases) ? parsed.releases : [];
      for (const item of releases) {
        const platform = normalizeReleasePlatform(item?.platform);
        if (!platform) continue;
        const release = sanitizeReleaseRecord(item, platform, safeFilename);
        if (!release) continue;
        releasesByPlatform.set(platform, release);
      }
    } catch (error) {
      console.error('[RELEASES] Load failed:', error && error.message ? error.message : String(error));
    }
  }

  return {
    releasesByPlatform,
    releaseFilePath,
    serialize,
    persist,
    load,
    normalizeReleasePlatform,
    normalizeChannel,
    parsePositiveInt,
    sanitizeReleaseRecord: (input, platform) => sanitizeReleaseRecord(input, platform, safeFilename),
    sanitizeReleaseForClient,
  };
}

module.exports = {
  createReleaseStore,
  normalizeReleasePlatform,
  normalizeChannel,
  parsePositiveInt,
  sanitizeReleaseForClient,
};
