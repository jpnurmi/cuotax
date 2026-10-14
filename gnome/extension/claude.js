// SPDX-License-Identifier: MIT

/* global TextDecoder, TextEncoder */

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Soup from 'gi://Soup?version=3.0';

import {BackendError} from './backend.js';
import {parseClaudeQuota} from './quota.js';

Gio._promisify(Gio.File.prototype, 'load_contents_async', 'load_contents_finish');
Gio._promisify(Gio.File.prototype, 'replace_contents_bytes_async', 'replace_contents_finish');
Gio._promisify(Gio.File.prototype, 'make_directory_async', 'make_directory_finish');
Gio._promisify(Gio.File.prototype, 'query_info_async', 'query_info_finish');
Gio._promisify(Gio.File.prototype, 'delete_async', 'delete_finish');
Gio._promisify(Soup.Session.prototype, 'send_and_read_async', 'send_and_read_finish');

function parseCredentials(data) {
    let credentials;
    try {
        credentials = JSON.parse(data);
    } catch {
        // Invalid credentials are reported as a missing login.
    }
    const oauth = credentials?.claudeAiOauth;
    if (typeof oauth?.accessToken !== 'string' || !oauth.accessToken)
        throw new BackendError('Claude Code login not found', 'Open Claude Code and run /login');
    return credentials;
}

export function parseToken(data, now = Date.now()) {
    const oauth = parseCredentials(data).claudeAiOauth;
    if (Number.isFinite(oauth.expiresAt) && oauth.expiresAt <= now) throw expiredLogin();
    return oauth.accessToken;
}

function expiredLogin() {
    return new BackendError(
        'Claude login expired or unavailable',
        'The saved login could not be renewed; run /login in Claude Code',
    );
}

async function readCredentials(file, cancellable) {
    let contents, etag;
    try {
        [contents, etag] = await file.load_contents_async(cancellable);
    } catch {
        throw new BackendError('Claude Code login not found', 'Open Claude Code and run /login');
    }
    return [parseCredentials(new TextDecoder().decode(contents)), etag];
}

function needsRefresh(oauth, rejected) {
    return (
        oauth.accessToken === rejected ||
        (Number.isFinite(oauth.expiresAt) && oauth.expiresAt <= Date.now() + 60 * 1000)
    );
}

async function lockRefresh(directory, cancellable) {
    // share Claude Code's refresh lock to avoid rotating the same token twice
    const lock = directory.get_child('.oauth_refresh.lock');
    for (let attempt = 0; attempt < 5; attempt++) {
        try {
            await lock.make_directory_async(GLib.PRIORITY_DEFAULT, cancellable);
            return lock;
        } catch (error) {
            if (!error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.EXISTS)) throw error;
        }
        try {
            const info = await lock.query_info_async(
                'time::modified',
                Gio.FileQueryInfoFlags.NONE,
                GLib.PRIORITY_DEFAULT,
                cancellable,
            );
            if (Date.now() / 1000 - info.get_attribute_uint64('time::modified') >= 60) {
                await lock.delete_async(GLib.PRIORITY_DEFAULT, cancellable);
                continue;
            }
        } catch (error) {
            if (!error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.NOT_FOUND)) throw error;
            continue;
        }
        await new Promise((resolve) => {
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
                resolve();
                return GLib.SOURCE_REMOVE;
            });
        });
    }
    throw new BackendError('Claude login renewal busy', 'Another process is renewing the login');
}

async function saveCredentials(file, previous, renewed) {
    for (let attempt = 0; attempt < 3; attempt++) {
        const [credentials, etag] = await readCredentials(file, null);
        const oauth = credentials.claudeAiOauth;
        if (
            oauth.accessToken !== previous.accessToken ||
            oauth.refreshToken !== previous.refreshToken
        )
            return parseToken(JSON.stringify(credentials));
        Object.assign(oauth, renewed);
        try {
            // finish saving rotated credentials even if the backend was disabled
            await file.replace_contents_bytes_async(
                new GLib.Bytes(new TextEncoder().encode(JSON.stringify(credentials))),
                etag,
                false,
                Gio.FileCreateFlags.PRIVATE | Gio.FileCreateFlags.REPLACE_DESTINATION,
                null,
            );
            return oauth.accessToken;
        } catch (error) {
            if (!error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.WRONG_ETAG)) throw error;
        }
    }
    throw new BackendError('Claude login renewal failed', 'Could not save the renewed credentials');
}

async function accessToken(cancellable, rejected, session) {
    const token = GLib.getenv('CLAUDE_CODE_OAUTH_TOKEN');
    if (token) return token;
    const directory = Gio.File.new_for_path(
        GLib.getenv('CLAUDE_CONFIG_DIR') || GLib.build_filenamev([GLib.get_home_dir(), '.claude']),
    );
    const file = directory.get_child('.credentials.json');
    let [credentials] = await readCredentials(file, cancellable);
    if (!needsRefresh(credentials.claudeAiOauth, rejected))
        return credentials.claudeAiOauth.accessToken;
    if (!credentials.claudeAiOauth.refreshToken) return parseToken(JSON.stringify(credentials));

    const lock = await lockRefresh(directory, cancellable);
    try {
        [credentials] = await readCredentials(file, cancellable);
        const oauth = credentials.claudeAiOauth;
        if (!needsRefresh(oauth, rejected)) return oauth.accessToken;
        if (typeof oauth.refreshToken !== 'string' || !oauth.refreshToken) throw expiredLogin();

        const body = {
            grant_type: 'refresh_token',
            refresh_token: oauth.refreshToken,
            client_id:
                oauth.clientId ||
                GLib.getenv('CLAUDE_CODE_OAUTH_CLIENT_ID') ||
                '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
        };
        if (Array.isArray(oauth.scopes) && oauth.scopes.length) body.scope = oauth.scopes.join(' ');
        const message = Soup.Message.new('POST', 'https://platform.claude.com/v1/oauth/token');
        message.set_request_body_from_bytes(
            'application/json',
            new GLib.Bytes(new TextEncoder().encode(JSON.stringify(body))),
        );
        let result;
        try {
            const bytes = await session.send_and_read_async(
                message,
                GLib.PRIORITY_DEFAULT,
                cancellable,
            );
            result = JSON.parse(new TextDecoder().decode(bytes.get_data()));
        } catch {
            throw new BackendError(
                'Claude login renewal failed',
                'Could not renew the saved login; CuotaX will retry automatically',
            );
        }
        if (message.status_code === 401 || result?.error === 'invalid_grant') throw expiredLogin();
        if (message.status_code !== Soup.Status.OK)
            throw new BackendError(
                'Claude login renewal failed',
                `The token endpoint returned HTTP ${message.status_code}`,
            );
        if (
            typeof result?.access_token !== 'string' ||
            !result.access_token ||
            !Number.isFinite(result.expires_in) ||
            result.expires_in <= 0 ||
            (result.refresh_token !== undefined &&
                (typeof result.refresh_token !== 'string' || !result.refresh_token))
        )
            throw new BackendError('Claude login renewal failed', 'The token response was invalid');

        const renewed = {
            accessToken: result.access_token,
            refreshToken: result.refresh_token ?? oauth.refreshToken,
            expiresAt: Date.now() + result.expires_in * 1000,
        };
        if (typeof result.scope === 'string')
            renewed.scopes = result.scope.split(/\s+/).filter(Boolean);
        if (Number.isFinite(result.refresh_token_expires_in) && result.refresh_token_expires_in > 0)
            renewed.refreshTokenExpiresAt = Date.now() + result.refresh_token_expires_in * 1000;
        try {
            return await saveCredentials(file, oauth, renewed);
        } catch {
            throw new BackendError(
                'Claude login renewal failed',
                'Could not save the renewed credentials',
            );
        }
    } finally {
        await lock.delete_async(GLib.PRIORITY_DEFAULT, null);
    }
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
            let token = await this._token(this._cancellable, null, this._session);
            if (!this._active) return;
            let message, bytes;
            for (let attempt = 0; attempt < 2; attempt++) {
                message = Soup.Message.new('GET', 'https://api.anthropic.com/api/oauth/usage');
                message.request_headers.append('Authorization', `Bearer ${token}`);
                message.request_headers.append('anthropic-beta', 'oauth-2025-04-20');
                message.request_headers.append('Accept', 'application/json');
                bytes = await this._session.send_and_read_async(
                    message,
                    GLib.PRIORITY_DEFAULT,
                    this._cancellable,
                );
                if (!this._active) return;
                if (message.status_code !== 401 || attempt) break;
                const renewed = await this._token(this._cancellable, token, this._session);
                if (!this._active) return;
                if (renewed === token) break;
                token = renewed;
            }
            if (!this._active) return;
            if (message.status_code === 401 || message.status_code === 403) throw expiredLogin();
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
