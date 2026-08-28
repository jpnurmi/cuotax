// SPDX-License-Identifier: MIT

import Cairo from 'cairo';
import Pango from 'gi://Pango';
import PangoCairo from 'gi://PangoCairo';

import {
    displayPercent,
    formatPercent,
    formatReset,
    formatTime,
    paceColor,
    quotaStatus,
} from '../extension/quota.js';

const WIDTH = 740;
const HEIGHT = 442;
const NOW = Date.parse('2026-08-28T12:23:00Z');
const quota = {
    fiveHour: {usedPercent: 68, resetsAt: Date.parse('2026-08-28T14:53:00Z')},
    weekly: {usedPercent: 42, resetsAt: Date.parse('2026-09-01T16:13:00Z')},
    updatedAt: NOW,
};

function roundedRectangle(cr, x, y, width, height, radius) {
    cr.newSubPath();
    cr.arc(x + width - radius, y + radius, radius, -Math.PI / 2, 0);
    cr.arc(x + width - radius, y + height - radius, radius, 0, Math.PI / 2);
    cr.arc(x + radius, y + height - radius, radius, Math.PI / 2, Math.PI);
    cr.arc(x + radius, y + radius, radius, Math.PI, (3 * Math.PI) / 2);
    cr.closePath();
}

function setColor(cr, color, alpha = 1) {
    cr.setSourceRGBA(color.red / 255, color.green / 255, color.blue / 255, alpha);
}

function text(cr, value, x, y, size, color, weight = Pango.Weight.NORMAL) {
    const layout = PangoCairo.create_layout(cr);
    const font = Pango.FontDescription.from_string(`Cantarell ${size}`);
    font.set_weight(weight);
    layout.set_font_description(font);
    layout.set_text(value, -1);
    setColor(cr, color);
    cr.moveTo(x, y);
    PangoCairo.show_layout(cr, layout);
}

function drawQuotaIcon(cr, x, y, status) {
    const color = paceColor(status) ?? {red: 210, green: 210, blue: 210};
    const radius = 14;
    const start = -Math.PI / 2;
    cr.setLineWidth(3.2);
    setColor(cr, color, 0.25);
    cr.arc(x, y, radius, 0, 2 * Math.PI);
    cr.stroke();
    setColor(cr, color);
    cr.arc(x, y, radius, start, start + (2 * Math.PI * status.remainingPercent) / 100);
    cr.stroke();

    cr.setLineWidth(2.4);
    cr.setLineCap(Cairo.LineCap.ROUND);
    cr.moveTo(x - 4.2, y - 4.4);
    cr.lineTo(x + 0.4, y);
    cr.lineTo(x - 4.2, y + 4.4);
    cr.moveTo(x + 1.8, y + 4.4);
    cr.lineTo(x + 6.2, y + 4.4);
    cr.stroke();
}

function windowLine(cr, label, value, window, y) {
    const status = quotaStatus({[window]: value}, NOW);
    const color = paceColor(status) ?? {red: 178, green: 178, blue: 178};
    setColor(cr, color);
    cr.arc(56, y + 14, 6, 0, 2 * Math.PI);
    cr.fill();
    const used = displayPercent(value.usedPercent);
    const reference = ` (${used <= status.onTrackPercent ? '≤' : '>'}${formatPercent(status.onTrackPercent)})`;
    text(
        cr,
        `${label}  ${formatPercent(used)}${reference} · ${formatReset(value.resetsAt)}`,
        78,
        y,
        20,
        {red: 205, green: 205, blue: 210},
    );
}

if (!ARGV[0]) throw new Error('usage: screenshot.js OUTPUT');

const surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, WIDTH, HEIGHT);
const cr = new Cairo.Context(surface);

const background = new Cairo.LinearGradient(0, 0, WIDTH, HEIGHT);
background.addColorStopRGB(0, 0.08, 0.09, 0.12);
background.addColorStopRGB(1, 0.18, 0.2, 0.25);
cr.setSource(background);
cr.paint();

cr.setSourceRGBA(0.035, 0.035, 0.04, 0.97);
cr.rectangle(0, 0, WIDTH, 64);
cr.fill();

const overall = quotaStatus(quota, NOW);
const overallColor = paceColor(overall);
cr.setSourceRGBA(0.3, 0.3, 0.32, 0.95);
roundedRectangle(cr, 164, 7, 154, 50, 25);
cr.fill();
drawQuotaIcon(cr, 198, 32, overall);
text(cr, '68%', 223, 17, 23, overallColor, Pango.Weight.NORMAL);
text(cr, '◉  ⌘  ◆  100%', 555, 18, 19, {red: 238, green: 238, blue: 240});

cr.setSourceRGBA(0, 0, 0, 0.32);
roundedRectangle(cr, 13, 81, 718, 354, 29);
cr.fill();
cr.setSourceRGBA(0.18, 0.18, 0.2, 0.985);
roundedRectangle(cr, 10, 77, 718, 352, 29);
cr.fillPreserve();
cr.setSourceRGBA(0.32, 0.32, 0.36, 0.55);
cr.setLineWidth(1.5);
cr.stroke();

windowLine(cr, '5-hour', quota.fiveHour, 'fiveHour', 112);
windowLine(cr, 'Weekly', quota.weekly, 'weekly', 177);

cr.setSourceRGBA(0.38, 0.38, 0.41, 0.5);
cr.rectangle(48, 251, 642, 1.5);
cr.fill();
text(cr, `Updated ${formatTime(quota.updatedAt)}`, 49, 290, 20, {
    red: 190,
    green: 190,
    blue: 195,
});
text(cr, 'Refresh', 49, 363, 20, {red: 248, green: 248, blue: 250});

surface.writeToPNG(ARGV[0]);
