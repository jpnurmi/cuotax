// SPDX-License-Identifier: MIT

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {CodexBackend} from './backend.js';
import {
    displayPercent,
    formatPercent,
    formatReset,
    formatTime,
    highestPercent,
    paceLabel,
    quotaStatus,
} from './quota.js';

const REFRESH_SECONDS = 5 * 60;
const OPEN_REFRESH_AGE_MS = 60 * 1000;

function infoItem(text, styleClass = '') {
    const item = new PopupMenu.PopupMenuItem(text, {
        reactive: false,
        can_focus: false,
    });
    item.setSensitive(false);
    if (styleClass) item.add_style_class_name(styleClass);
    return item;
}

const QuotaIcon = GObject.registerClass(
    class QuotaIcon extends St.DrawingArea {
        _init() {
            super._init({style_class: 'cuotax-icon'});
            this._remainingPercent = null;
            this.connect('repaint', () => this._repaint());
        }

        render(status) {
            this._remainingPercent = status.remainingPercent;
            this.remove_style_class_name('cuotax-icon-warning');
            this.remove_style_class_name('cuotax-icon-critical');
            this.remove_style_class_name('cuotax-icon-unavailable');
            if (status.level === 'warning') this.add_style_class_name('cuotax-icon-warning');
            else if (status.level === 'critical') this.add_style_class_name('cuotax-icon-critical');
            else if (status.level === 'unavailable')
                this.add_style_class_name('cuotax-icon-unavailable');
            this.queue_repaint();
        }

        _repaint() {
            const [width, height] = this.get_surface_size();
            const color = this.get_theme_node().get_foreground_color();
            const cr = this.get_context();
            const size = Math.min(width, height);
            const scale = size / 16;
            const x = width / 2;
            const y = height / 2;
            const lineWidth = 1.7 * scale;
            const radius = size / 2 - lineWidth / 2;
            const start = -Math.PI / 2;

            cr.setLineWidth(lineWidth);
            cr.setSourceRGBA(color.red / 255, color.green / 255, color.blue / 255, 0.25);
            cr.arc(x, y, radius, 0, 2 * Math.PI);
            cr.stroke();

            if (this._remainingPercent !== null) {
                cr.setSourceColor(color);
                cr.arc(x, y, radius, start, start + (2 * Math.PI * this._remainingPercent) / 100);
                cr.stroke();
            }

            cr.setLineWidth(1.4 * scale);
            cr.setSourceColor(color);
            cr.moveTo(x - 2.2 * scale, y - 2.3 * scale);
            cr.lineTo(x + 0.2 * scale, y);
            cr.lineTo(x - 2.2 * scale, y + 2.3 * scale);
            cr.moveTo(x + 0.8 * scale, y + 2.3 * scale);
            cr.lineTo(x + 3.1 * scale, y + 2.3 * scale);
            cr.stroke();
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
            this.renderLoading();
        }

        renderLoading() {
            this._label.text = '…';
            this._icon.render(quotaStatus(null));
            this.menu.removeAll();
            this.menu.addMenuItem(infoItem('Loading Codex quota…'));
            this._addRefresh();
        }

        render(quota, error = null) {
            const percent = highestPercent(quota);
            const displayed = displayPercent(percent);
            const status = quotaStatus(quota);
            const level = status.level;
            const pace = paceLabel(status);
            this._icon.render(status);
            this._label.text = displayed === null ? '—' : `${Math.round(displayed)}%`;
            this.set_accessible_name(
                displayed === null
                    ? 'CuotaX unavailable'
                    : `CuotaX ${Math.round(displayed)} percent, ${pace.toLowerCase()}`,
            );

            this.remove_style_class_name('cuotax-warning');
            this.remove_style_class_name('cuotax-critical');
            if (level === 'warning') this.add_style_class_name('cuotax-warning');
            else if (level === 'critical') this.add_style_class_name('cuotax-critical');

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
            this._label.text = '!';
            this._icon.render(quotaStatus(null));
            this.set_accessible_name(`CuotaX unavailable: ${error.message}`);
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
            item.insert_child_at_index(
                new St.Icon({
                    icon_name: 'media-record-symbolic',
                    style_class: `cuotax-pace-icon cuotax-pace-${status.level}`,
                }),
                0,
            );
            return item;
        }

        _addRefresh() {
            const refresh = new PopupMenu.PopupMenuItem('Refresh');
            refresh.connect('activate', () => this._onRefresh());
            this.menu.addMenuItem(refresh);
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
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, REFRESH_SECONDS, () => {
            this._backend.refresh();
            return GLib.SOURCE_CONTINUE;
        });
        this._backend.refresh();
    }

    disable() {
        if (this._timer) GLib.source_remove(this._timer);
        this._timer = 0;
        this._backend?.destroy();
        this._backend = null;
        this._indicator?.destroy();
        this._indicator = null;
        this._quota = null;
    }

    _refreshWhenOpened() {
        if (!this._quota || Date.now() - this._quota.updatedAt >= OPEN_REFRESH_AGE_MS)
            this._backend.refresh();
    }
}
