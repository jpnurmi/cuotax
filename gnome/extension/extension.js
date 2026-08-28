// SPDX-License-Identifier: MIT

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {CodexBackend} from './backend.js';
import {UpdateChecker} from './update.js';
import {
    displayPercent,
    formatPercent,
    formatReset,
    formatTime,
    highestPercent,
    paceColor,
    paceLabel,
    quotaStatus,
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
            super._init({style_class: 'cuotax-icon'});
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
        _init(onRefresh, onOpen) {
            super._init(0.0, 'CuotaX');

            const box = new St.BoxLayout({style_class: 'panel-status-menu-box cuotax-box'});
            this._icon = new QuotaIcon();
            box.add_child(this._icon);
            this._label = new St.Label({
                text: '…',
                y_align: Clutter.ActorAlign.CENTER,
                style_class: 'cuotax-label',
            });
            box.add_child(this._label);
            this.add_child(box);

            this.menu.connect('open-state-changed', (_menu, open) => {
                if (open) onOpen();
            });
            this._onRefresh = onRefresh;
            this._updateAvailable = false;
            this._quota = null;
            this._error = null;
            this.renderLoading();
        }

        setUpdateAvailable() {
            if (this._updateAvailable) return;
            this._updateAvailable = true;
            this._icon.setUpdateAvailable();
            this._setAccessibleName(this.get_accessible_name() ?? 'CuotaX');
        }

        renderLoading() {
            this._quota = null;
            this._error = null;
            this._label.text = '…';
            this._icon.render(quotaStatus(null));
            this.menu.removeAll();
            this.menu.addMenuItem(infoItem('Loading Codex quota…'));
            this._addRefresh();
        }

        render(quota, error = null) {
            this._quota = quota;
            this._error = error;
            const percent = highestPercent(quota);
            const displayed = displayPercent(percent);
            const status = quotaStatus(quota);
            const pace = paceLabel(status);
            const color = paceColor(status);
            this._icon.render(status);
            this._label.set_style(colorStyle(color));
            this._label.text = displayed === null ? '—' : `${Math.round(displayed)}%`;
            this._setAccessibleName(
                displayed === null
                    ? 'CuotaX unavailable'
                    : `CuotaX ${Math.round(displayed)} percent, ${pace.toLowerCase()}`,
            );

            this.menu.removeAll();
            this.menu.addMenuItem(this._quotaItem('5-hour', quota.fiveHour, 'fiveHour'));
            this.menu.addMenuItem(this._quotaItem('Weekly', quota.weekly, 'weekly'));
            if (error) {
                this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
                this.menu.addMenuItem(
                    infoItem('Refresh failed · showing previous data', 'cuotax-error'),
                );
                this.menu.addMenuItem(infoItem(error.diagnostic, 'cuotax-diagnostic'));
            }
            this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
            this.menu.addMenuItem(infoItem(`Updated ${formatTime(quota.updatedAt)}`));
            this._addRefresh();
        }

        renderError(error) {
            this._quota = null;
            this._error = error;
            this._label.text = '!';
            this._label.set_style('');
            this._icon.render(quotaStatus(null));
            this._setAccessibleName(`CuotaX unavailable: ${error.message}`);
            this.menu.removeAll();
            this.menu.addMenuItem(infoItem(error.message, 'cuotax-error'));
            this.menu.addMenuItem(infoItem(error.diagnostic, 'cuotax-diagnostic'));
            this._addRefresh();
        }

        _quotaItem(label, quota, window) {
            const status = quotaStatus({[window]: quota});
            const used = displayPercent(quota?.usedPercent);
            const reference =
                used === null || status.onTrackPercent === null
                    ? ''
                    : ` (${used <= status.onTrackPercent ? '≤' : '>'}${formatPercent(status.onTrackPercent)})`;
            const text = quota
                ? `${label}  ${formatPercent(used)}${reference} · ${formatReset(quota.resetsAt)}`
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
            const refresh = new PopupMenu.PopupMenuItem('Refresh');
            refresh.connect('activate', () => this._onRefresh());
            this.menu.addMenuItem(refresh);
        }

        _setAccessibleName(name) {
            const suffix = this._updateAvailable ? ', update available' : '';
            this.set_accessible_name(`${name.replace(/, update available$/, '')}${suffix}`);
        }
    },
);

export default class CuotaXExtension extends Extension {
    enable() {
        this._quota = null;
        this._indicator = new CuotaXIndicator(
            () => this._backend.refresh(),
            () => this._refreshWhenOpened(),
        );
        Main.panel.addToStatusArea(this.uuid, this._indicator);

        this._backend = new CodexBackend(
            (quota) => {
                this._quota = quota;
                this._indicator?.render(quota);
            },
            (error) => {
                if (this._quota) this._indicator?.render(this._quota, error);
                else this._indicator?.renderError(error);
            },
        );
        this._updateChecker = new UpdateChecker(() => this._indicator?.setUpdateAvailable());
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
            this._backend.refresh();
            return GLib.SOURCE_CONTINUE;
        });
        this._updateTimer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, UPDATE_SECONDS, () => {
            this._updateChecker.check();
            return GLib.SOURCE_CONTINUE;
        });
        this._backend.refresh();
        this._updateChecker.check();
    }

    disable() {
        if (this._sleepSignal) Gio.DBus.system.signal_unsubscribe(this._sleepSignal);
        this._sleepSignal = 0;
        if (this._timer) GLib.source_remove(this._timer);
        this._timer = 0;
        if (this._updateTimer) GLib.source_remove(this._updateTimer);
        this._updateTimer = 0;
        this._backend?.destroy();
        this._backend = null;
        this._updateChecker?.destroy();
        this._updateChecker = null;
        this._indicator?.destroy();
        this._indicator = null;
        this._quota = null;
    }

    _refreshWhenOpened() {
        if (!this._quota || Date.now() - this._quota.updatedAt >= OPEN_REFRESH_AGE_MS)
            this._backend.refresh();
    }

    _refreshAfterWake() {
        this._backend?.refresh();
        this._updateChecker?.check();
    }
}
