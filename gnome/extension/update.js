// SPDX-License-Identifier: MIT

/* global TextDecoder */

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Soup from 'gi://Soup?version=3.0';

import {BUILD_COMMIT} from './build.js';

const API_URL = 'https://api.github.com/repos/jpnurmi/cuotax/compare';
const COMMIT_PATTERN = /^[0-9a-f]{40}$/;

Gio._promisify(Soup.Session.prototype, 'send_and_read_async', 'send_and_read_finish');

export function hasUpdate(response) {
    try {
        const comparison = JSON.parse(response);
        return Number.isInteger(comparison.ahead_by) && comparison.ahead_by > 0;
    } catch {
        return false;
    }
}

export class UpdateChecker {
    constructor(onUpdate, buildCommit = BUILD_COMMIT) {
        this._onUpdate = onUpdate;
        this._buildCommit = buildCommit;
        this._session = new Soup.Session({timeout: 15});
        this._cancellable = null;
    }

    async check() {
        if (!COMMIT_PATTERN.test(this._buildCommit) || this._cancellable) return;

        this._cancellable = new Gio.Cancellable();
        try {
            const message = Soup.Message.new('GET', `${API_URL}/${this._buildCommit}...main`);
            message.request_headers.append('Accept', 'application/vnd.github+json');
            message.request_headers.append('User-Agent', 'CuotaX');
            const bytes = await this._session.send_and_read_async(
                message,
                GLib.PRIORITY_DEFAULT,
                this._cancellable,
            );
            if (message.status_code !== Soup.Status.OK) return;
            if (hasUpdate(new TextDecoder().decode(bytes.get_data()))) this._onUpdate();
        } catch {
            // Update checks are best-effort and should never disturb quota reporting.
        } finally {
            this._cancellable = null;
        }
    }

    destroy() {
        this._cancellable?.cancel();
        this._cancellable = null;
    }
}
