// SPDX-License-Identifier: MIT

/* global TextDecoder */

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Soup from 'gi://Soup?version=3.0';

import {BackendError} from './backend.js';
import {parseClaudeQuota} from './quota.js';

Gio._promisify(Gio.File.prototype, 'load_contents_async', 'load_contents_finish');
Gio._promisify(Soup.Session.prototype, 'send_and_read_async', 'send_and_read_finish');

export function parseToken(data, now = Date.now()) {
    let oauth;
    try {
        oauth = JSON.parse(data).claudeAiOauth;
    } catch {
        // Invalid credentials are reported as a missing login.
    }
    if (typeof oauth?.accessToken !== 'string' || !oauth.accessToken)
        throw new BackendError('Claude Code login not found', 'Open Claude Code and run /login');
    if (Number.isFinite(oauth.expiresAt) && oauth.expiresAt <= now)
        throw new BackendError(
            'Claude login expired',
            'Open Claude Code to renew the login, then refresh',
        );
    return oauth.accessToken;
}

async function accessToken(cancellable) {
    const token = GLib.getenv('CLAUDE_CODE_OAUTH_TOKEN');
    if (token) return token;
    const directory =
        GLib.getenv('CLAUDE_CONFIG_DIR') || GLib.build_filenamev([GLib.get_home_dir(), '.claude']);
    const file = Gio.File.new_for_path(GLib.build_filenamev([directory, '.credentials.json']));
    let contents;
    try {
        [contents] = await file.load_contents_async(cancellable);
    } catch {
        throw new BackendError('Claude Code login not found', 'Open Claude Code and run /login');
    }
    return parseToken(new TextDecoder().decode(contents));
}

async function cachedQuota(cancellable) {
    const directory =
        GLib.getenv('CLAUDE_CONFIG_DIR') || GLib.build_filenamev([GLib.get_home_dir(), '.claude']);
    const file = Gio.File.new_for_path(GLib.build_filenamev([directory, 'cuotax-usage.json']));
    try {
        const [contents] = await file.load_contents_async(cancellable);
        const usage = JSON.parse(new TextDecoder().decode(contents));
        const age = Date.now() - usage.updatedAt;
        if (!Number.isFinite(usage.updatedAt) || age < 0 || age >= 5 * 60 * 1000) return null;
        return parseClaudeQuota(usage, usage.updatedAt);
    } catch {
        return null;
    }
}

export class ClaudeBackend {
    constructor(
        onSuccess,
        onError,
        token = accessToken,
        session = new Soup.Session({timeout: 15}),
        cache = cachedQuota,
    ) {
        this._onSuccess = onSuccess;
        this._onError = onError;
        this._token = token;
        this._session = session;
        this._cache = cache;
        this._active = true;
        this._cancellable = null;
        this._queued = false;
        this._monitor = null;
        this._watchUsage();
    }

    _watchUsage() {
        if (this._monitor) return;
        const directory =
            GLib.getenv('CLAUDE_CONFIG_DIR') ||
            GLib.build_filenamev([GLib.get_home_dir(), '.claude']);
        try {
            this._monitor = Gio.File.new_for_path(directory).monitor_directory(
                Gio.FileMonitorFlags.NONE,
                null,
            );
            this._monitor.connect('changed', (_monitor, file, other) => {
                if (
                    file?.get_basename() === 'cuotax-usage.json' ||
                    other?.get_basename() === 'cuotax-usage.json'
                )
                    this.refresh();
            });
        } catch {
            // Polling remains available until the Claude directory exists.
        }
    }

    async refresh(queue = true) {
        if (!this._active) return;
        this._watchUsage();
        if (this._cancellable) {
            this._queued ||= queue;
            return;
        }
        this._cancellable = new Gio.Cancellable();
        try {
            const quota = await this._cache(this._cancellable);
            if (!this._active) return;
            if (quota) {
                this._onSuccess(quota);
                return;
            }
            const token = await this._token(this._cancellable);
            if (!this._active) return;
            const message = Soup.Message.new('GET', 'https://api.anthropic.com/api/oauth/usage');
            message.request_headers.append('Authorization', `Bearer ${token}`);
            message.request_headers.append('anthropic-beta', 'oauth-2025-04-20');
            message.request_headers.append('Accept', 'application/json');
            const bytes = await this._session.send_and_read_async(
                message,
                GLib.PRIORITY_DEFAULT,
                this._cancellable,
            );
            if (!this._active) return;
            if (message.status_code === 401 || message.status_code === 403)
                throw new BackendError(
                    'Claude login expired or unavailable',
                    'Open Claude Code and run /login, then refresh',
                );
            if (message.status_code === 429)
                throw new BackendError(
                    'Claude usage requests are rate limited',
                    'Wait a few minutes before refreshing',
                );
            if (message.status_code !== Soup.Status.OK)
                throw new BackendError(
                    'Claude quota request failed',
                    `The usage endpoint returned HTTP ${message.status_code}`,
                );
            this._onSuccess(
                parseClaudeQuota(JSON.parse(new TextDecoder().decode(bytes.get_data()))),
            );
        } catch (error) {
            if (!this._active) return;
            this._onError(
                error instanceof BackendError
                    ? error
                    : new BackendError(
                          'Claude quota request failed',
                          'Could not read subscription usage',
                      ),
            );
        } finally {
            this._cancellable = null;
            if (this._active && this._queued) {
                this._queued = false;
                this.refresh();
            }
        }
    }

    destroy() {
        this._active = false;
        this._queued = false;
        this._cancellable?.cancel();
        this._cancellable = null;
        this._monitor?.cancel();
        this._monitor = null;
    }
}
