// SPDX-License-Identifier: MIT

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Pango from 'gi://Pango';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {CodexBackend} from './backend.js';
import {ClaudeBackend} from './claude.js';
import {UpdateChecker} from './update.js';
import {
    displayPercent,
    formatPercent,
    formatPercentages,
    formatReset,
    formatTime,
    highestPercent,
    nextReset,
    paceColor,
    paceLabel,
    quotaStatus,
    resetMessage,
} from './quota.js';

const REFRESH_SECONDS = 5 * 60;
const OPEN_REFRESH_AGE_MS = 60 * 1000;
const UPDATE_SECONDS = 24 * 60 * 60;

function infoItem(text, styleClass = '') {
    const item = new PopupMenu.PopupMenuItem(text, {
        reactive: false,
        can_focus: false,
    });
    item.setSensitive(false);
    if (styleClass) item.add_style_class_name(styleClass);
    return item;
}

function colorStyle(color) {
    return color ? `color: rgb(${color.red}, ${color.green}, ${color.blue});` : '';
}

const QuotaIcon = GObject.registerClass(
    class QuotaIcon extends St.DrawingArea {
        _init() {
            super._init({
                style_class: 'cuotax-icon',
                y_align: Clutter.ActorAlign.CENTER,
            });
            this._color = null;
            this._remainingPercent = null;
            this._updateAvailable = false;
            this.connect('repaint', () => this._repaint());
        }

        render(status) {
            this._color = paceColor(status);
            this._remainingPercent = status.remainingPercent;
            this.queue_repaint();
        }

        setUpdateAvailable() {
            this._updateAvailable = true;
            this.queue_repaint();
        }

        _repaint() {
            const [width, height] = this.get_surface_size();
            const themeColor = this.get_theme_node().get_foreground_color();
            const color = this._color ?? themeColor;
            const alpha = themeColor.alpha / 255;
            const cr = this.get_context();
            const size = Math.min(width, height);
            const scale = size / 16;
            const x = width / 2;
            const y = height / 2;
            const lineWidth = 1.7 * scale;
            const radius = size / 2 - lineWidth / 2;
            const start = -Math.PI / 2;

            cr.setLineWidth(lineWidth);
            cr.setSourceRGBA(color.red / 255, color.green / 255, color.blue / 255, 0.25 * alpha);
            cr.arc(x, y, radius, 0, 2 * Math.PI);
            cr.stroke();

            if (this._remainingPercent !== null) {
                cr.setSourceRGBA(color.red / 255, color.green / 255, color.blue / 255, alpha);
                cr.arc(x, y, radius, start, start + (2 * Math.PI * this._remainingPercent) / 100);
                cr.stroke();
            }

            cr.setLineWidth(1.4 * scale);
            cr.setSourceRGBA(color.red / 255, color.green / 255, color.blue / 255, alpha);
            cr.moveTo(x - 2.2 * scale, y - 2.3 * scale);
            cr.lineTo(x + 0.2 * scale, y);
            cr.lineTo(x - 2.2 * scale, y + 2.3 * scale);
            cr.moveTo(x + 0.8 * scale, y + 2.3 * scale);
            cr.lineTo(x + 3.1 * scale, y + 2.3 * scale);
            cr.stroke();

            if (this._updateAvailable) {
                const badgeRadius = 2.5 * scale;
                const badgeX = x - size / 2 + badgeRadius;
                const badgeY = y + size / 2 - badgeRadius;
                cr.setSourceRGB(22 / 255, 136 / 255, 248 / 255);
                cr.arc(badgeX, badgeY, badgeRadius, 0, 2 * Math.PI);
                cr.fill();
            }
        }
    },
);

const CuotaXIndicator = GObject.registerClass(
    class CuotaXIndicator extends PanelMenu.Button {
        _init(onRefresh, onOpen, onToggle, selection, states) {
            super._init(0.0, 'CuotaX');

            const box = new St.BoxLayout({style_class: 'panel-status-menu-box cuotax-box'});
            this._icon = new QuotaIcon();
            box.add_child(this._icon);
            const labels = new St.BoxLayout({
                orientation: Clutter.Orientation.VERTICAL,
                y_align: Clutter.ActorAlign.CENTER,
            });
            this._labels = new Map();
            for (const provider of ['codex', 'claude']) {
                const label = new St.Label({
                    text: '…',
                    x_align: Clutter.ActorAlign.CENTER,
                    style_class: 'cuotax-label',
                });
                label.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;
                this._labels.set(provider, label);
                labels.add_child(label);
            }
            box.add_child(labels);
            this._updateBadge = new St.Widget({
                style_class: 'cuotax-update-badge',
                y_align: Clutter.ActorAlign.CENTER,
            });
            box.add_child(this._updateBadge);
            this.add_child(box);

            this.menu.connect('open-state-changed', (_menu, open) => {
                if (open) {
                    onOpen();
                    this.updateMenu();
                }
            });
            this._onRefresh = onRefresh;
            this._onToggle = onToggle;
            this._selection = selection;
            this._states = states;
            this._updateAvailable = false;
            this.render();
        }

        setUpdateAvailable() {
            if (this._updateAvailable) return;
            this._updateAvailable = true;
            this._icon.setUpdateAvailable();
            this.render();
        }

        render() {
            const states = this._states();
            const stacked = this._selection().size > 1;
            this._icon.visible = !stacked;
            this._updateBadge.visible = stacked && this._updateAvailable;
            const names = [];
            let highest = null;
            let percent = -1;
            for (const [provider, label] of this._labels) {
                const state = states.get(provider);
                label.visible = Boolean(state);
                if (!state) continue;
                const {quota, error} = state;
                const used = highestPercent(quota);
                const displayed = displayPercent(used);
                const status = quotaStatus(quota);
                label.set_style_class_name(
                    stacked ? 'cuotax-label cuotax-label-stacked' : 'cuotax-label',
                );
                label.x_align = stacked ? Clutter.ActorAlign.START : Clutter.ActorAlign.CENTER;
                label.set_style(colorStyle(paceColor(status)));
                const text = quota ? formatPercentages(quota) : error ? '!' : '…';
                const prefix = provider === 'claude' ? 'CC' : 'CX';
                const value = stacked ? `${prefix} ${text}` : text;
                label.clutter_text.set_markup(
                    GLib.markup_escape_text(value, -1).replaceAll(
                        '-',
                        '<span font_family="monospace">-</span>',
                    ),
                );
                if (highest === null || (used ?? -1) > percent) {
                    highest = quota;
                    percent = used ?? -1;
                }
                const title = provider === 'claude' ? 'Claude' : 'Codex';
                const usage = [
                    ['5-hour', quota?.fiveHour],
                    ['weekly', quota?.weekly],
                    ['Fable weekly', quota?.fable],
                ]
                    .filter(([, value]) => Number.isFinite(value?.usedPercent))
                    .map(([window, value]) => `${window} ${formatPercent(value.usedPercent)} used`)
                    .join(', ');
                names.push(
                    quota
                        ? displayed === null
                            ? `${title} unavailable`
                            : `${title} ${usage}, ${paceLabel(status).toLowerCase()}`
                        : error
                          ? `${title} unavailable: ${error.message}`
                          : `${title} loading`,
                );
            }
            this._icon.render(quotaStatus(highest));
            const suffix = this._updateAvailable ? ', update available' : '';
            this.set_accessible_name(`CuotaX ${names.join('; ')}${suffix}`);
            this.updateMenu();
        }

        _quotaItem(label, quota, window) {
            const status = quotaStatus({[window]: quota});
            const used = displayPercent(quota?.usedPercent);
            const reference =
                used === null || status.onTrackPercent === null
                    ? ''
                    : ` (${used <= status.onTrackPercent ? '≤' : '>'}${formatPercent(status.onTrackPercent)})`;
            const text = quota
                ? `${label}  ${formatPercent(used)}${reference} · ${formatReset(quota.resetsAt, Date.now(), window !== 'fiveHour')}`
                : `${label}  —`;
            const item = infoItem(text);
            const pacing =
                status.onTrackPercent === null
                    ? 'pacing unavailable'
                    : `${formatPercent(status.onTrackPercent)} is on track`;
            item.set_accessible_name(
                quota
                    ? `${label}: ${formatPercent(quota.usedPercent)} used; ${pacing}`
                    : `${label}: unavailable`,
            );
            const icon = new St.Icon({
                icon_name: 'media-record-symbolic',
                style_class: 'cuotax-pace-icon',
            });
            icon.set_style(colorStyle(paceColor(status)));
            item.insert_child_at_index(icon, 0);
            return item;
        }

        _addRefresh() {
            const updates = [...this._states().values()]
                .map(({quota}) => quota?.updatedAt)
                .filter(Number.isFinite);
            const refresh = new PopupMenu.PopupMenuItem(
                updates.length ? `Refresh (${formatTime(Math.max(...updates))})` : 'Refresh',
            );
            refresh.connect('activate', () => this._onRefresh());
            this.menu.addMenuItem(refresh);
        }

        updateMenu() {
            this.menu.removeAll();
            for (const provider of ['codex', 'claude']) {
                const state = this._states().get(provider);
                const title = provider === 'claude' ? 'Claude' : 'Codex';
                const item = new PopupMenu.PopupMenuItem(title);
                const providers = this._selection();
                item.setOrnament(
                    providers.has(provider) ? PopupMenu.Ornament.CHECK : PopupMenu.Ornament.NONE,
                );
                item.setSensitive(!providers.has(provider) || providers.size > 1);
                item.connect('activate', () => this._onToggle(provider));
                this.menu.addMenuItem(item);
                if (state) this._addQuotaSection(provider, state);
                this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
            }
            this._addRefresh();
        }

        _addQuotaSection(provider, {quota, error}) {
            const add = (item) => {
                item.add_style_class_name('cuotax-quota');
                this.menu.addMenuItem(item);
            };
            if (quota) {
                add(this._quotaItem('5-hour', quota.fiveHour, 'fiveHour'));
                add(this._quotaItem('Weekly', quota.weekly, 'weekly'));
                if (quota.fable) add(this._quotaItem('Fable weekly', quota.fable, 'fable'));
                if (error) {
                    add(infoItem('Refresh failed · showing previous data', 'cuotax-error'));
                    add(infoItem(error.diagnostic, 'cuotax-diagnostic'));
                }
            } else if (error) {
                add(infoItem(error.message, 'cuotax-error'));
                add(infoItem(error.diagnostic, 'cuotax-diagnostic'));
            } else {
                add(infoItem(`Loading ${provider === 'claude' ? 'Claude' : 'Codex'} quota…`));
            }
        }
    },
);

export default class CuotaXExtension extends Extension {
    enable() {
        this._settings = this.getSettings();
        const selected = this._settings.get_user_value('providers')
            ? this._settings.get_strv('providers')
            : [this._settings.get_string('provider')];
        this._providers = new Set(selected.filter((value) => ['codex', 'claude'].includes(value)));
        if (!this._providers.size) this._providers.add('codex');
        this._states = new Map();
        for (const provider of ['codex', 'claude']) {
            if (this._providers.has(provider)) this._addProvider(provider);
        }
        this._indicator = new CuotaXIndicator(
            () => {
                for (const state of this._states.values()) state.backend.refresh();
            },
            () => {
                for (const state of this._states.values()) this._refreshWhenOpened(state);
            },
            (provider) => this._toggleProvider(provider),
            () => this._providers,
            () => this._states,
        );
        Main.panel.addToStatusArea(this.uuid, this._indicator);
        this._updateChecker = new UpdateChecker(() => {
            this._indicator.setUpdateAvailable();
        });
        this._sleepSignal = Gio.DBus.system.signal_subscribe(
            'org.freedesktop.login1',
            'org.freedesktop.login1.Manager',
            'PrepareForSleep',
            '/org/freedesktop/login1',
            null,
            Gio.DBusSignalFlags.NONE,
            (_connection, _sender, _path, _interface, _signal, parameters) => {
                const [sleeping] = parameters.deepUnpack();
                if (!sleeping) this._refreshAfterWake();
            },
        );
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, REFRESH_SECONDS, () => {
            for (const [provider, state] of this._states) {
                if (provider === 'claude') this._refreshWhenOpened(state, false);
                else state.backend.refresh(false);
            }
            return GLib.SOURCE_CONTINUE;
        });
        this._updateTimer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, UPDATE_SECONDS, () => {
            this._updateChecker.check();
            return GLib.SOURCE_CONTINUE;
        });
        for (const state of this._states.values()) state.backend.refresh();
        this._updateChecker.check();
    }

    _addProvider(provider) {
        const state = {quota: null, error: null, resetTimer: 0};
        this._states.set(provider, state);
        const Backend = provider === 'claude' ? ClaudeBackend : CodexBackend;
        state.backend = new Backend(
            (quota) => {
                const message = resetMessage(state.quota, quota);
                state.quota = quota;
                state.error = null;
                this._scheduleResetRefresh(provider, state, quota);
                this._indicator.render();
                if (message)
                    Main.notify(
                        `${provider === 'claude' ? 'Claude' : 'Codex'} quota reset`,
                        message,
                    );
            },
            (error) => {
                state.error = error;
                this._indicator.render();
            },
        );
    }

    _removeProvider(provider) {
        const state = this._states.get(provider);
        if (state.resetTimer) GLib.source_remove(state.resetTimer);
        state.backend.destroy();
        this._states.delete(provider);
    }

    _toggleProvider(provider) {
        if (this._providers.has(provider)) {
            if (this._providers.size === 1) return;
            this._providers.delete(provider);
            this._removeProvider(provider);
        } else {
            this._providers.add(provider);
            this._addProvider(provider);
            this._states.get(provider).backend.refresh();
        }
        this._settings.set_strv(
            'providers',
            ['codex', 'claude'].filter((value) => this._providers.has(value)),
        );
        this._settings.reset('provider');
        this._indicator.render();
    }

    disable() {
        if (this._sleepSignal) Gio.DBus.system.signal_unsubscribe(this._sleepSignal);
        this._sleepSignal = 0;
        if (this._timer) GLib.source_remove(this._timer);
        this._timer = 0;
        if (this._updateTimer) GLib.source_remove(this._updateTimer);
        this._updateTimer = 0;
        for (const provider of this._states.keys()) this._removeProvider(provider);
        this._updateChecker?.destroy();
        this._updateChecker = null;
        this._indicator?.destroy();
        this._indicator = null;
        this._settings = null;
    }

    _refreshWhenOpened(state, queue = true) {
        if (!state.quota || Date.now() - state.quota.updatedAt >= OPEN_REFRESH_AGE_MS)
            state.backend.refresh(queue);
    }

    _refreshAfterWake() {
        for (const state of this._states.values()) state.backend.refresh();
        this._updateChecker?.check();
    }

    _scheduleResetRefresh(provider, state, quota) {
        if (state.resetTimer) GLib.source_remove(state.resetTimer);
        state.resetTimer = 0;
        const expiry = provider === 'claude' ? quota.updatedAt + REFRESH_SECONDS * 1000 : null;
        const resets = [nextReset(quota), expiry].filter(Number.isFinite);
        const reset = resets.length ? Math.min(...resets) : null;
        if (reset === null) return;
        const seconds = Math.max(1, Math.ceil((reset - Date.now()) / 1000));
        state.resetTimer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, seconds, () => {
            state.resetTimer = 0;
            state.backend.refresh(false);
            return GLib.SOURCE_REMOVE;
        });
    }
}
