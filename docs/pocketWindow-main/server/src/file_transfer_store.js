const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function createFileTransferStore({
  transferDir,
  ttlMs,
  isClientTrusted,
}) {
  const transfers = new Map();

  function createToken() {
    return crypto.randomBytes(24).toString('hex');
  }

  function createFilePath(token, fileName) {
    return path.join(transferDir, `${token}-${fileName}`);
  }

  function add(transfer) {
    transfers.set(transfer.token, transfer);
  }

  function cleanupExpired(now = Date.now()) {
    for (const [token, item] of transfers.entries()) {
      if (Number(item.expiresAt || 0) > now) {
        continue;
      }
      transfers.delete(token);
      try {
        if (item.filePath && fs.existsSync(item.filePath)) {
          fs.unlinkSync(item.filePath);
        }
      } catch (error) {
        console.warn('[TRANSFER] Cleanup failed:', error && error.message ? error.message : String(error));
      }
    }
  }

  function requireTrusted(req, res) {
    cleanupExpired();
    const token = String(req.params.token || '').trim();
    const clientId = String(req.query.client_id || '').trim();
    const transfer = transfers.get(token);
    if (!token || !transfer) {
      res.status(404).json({ message: 'Transfer not found or expired' });
      return null;
    }
    if (!clientId || transfer.clientId !== clientId) {
      res.status(403).json({ message: 'Client is not allowed to access this transfer' });
      return null;
    }
    if (!isClientTrusted(transfer.deviceId, clientId)) {
      res.status(403).json({ message: 'Client is no longer trusted for this device' });
      return null;
    }
    if (!fs.existsSync(transfer.filePath)) {
      transfers.delete(token);
      res.status(404).json({ message: 'Transfer file missing' });
      return null;
    }
    return transfer;
  }

  return {
    transfers,
    ttlMs,
    createToken,
    createFilePath,
    add,
    cleanupExpired,
    requireTrusted,
  };
}

module.exports = {
  createFileTransferStore,
};
