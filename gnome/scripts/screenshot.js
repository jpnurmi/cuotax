// SPDX-License-Identifier: MIT

import Cairo from 'cairo';
import Pango from 'gi://Pango';
import PangoCairo from 'gi://PangoCairo';

import {
    displayPercent,
    formatPercent,
    formatPercentages,
    formatReset,
    formatTime,
    paceColor,
    quotaStatus,
} from '../extension/quota.js';

const WIDTH = 740;
const HEIGHT = 561;
const NOW = Date.parse('2026-08-28T12:23:00Z');
const codex = {
    fiveHour: {usedPercent: 68, resetsAt: Date.parse('2026-08-28T14:53:00Z')},
    weekly: {usedPercent: 42, resetsAt: Date.parse('2026-09-01T16:13:00Z')},
    updatedAt: NOW,
};
const claude = {
    fiveHour: {usedPercent: 26, resetsAt: Date.parse('2026-08-28T14:53:00Z')},
    weekly: {usedPercent: 6, resetsAt: Date.parse('2026-09-01T16:13:00Z')},
    fable: {usedPercent: 12, resetsAt: Date.parse('2026-09-01T16:13:00Z')},
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

function centeredText(cr, value, x, centerY, size, color, weight = Pango.Weight.NORMAL) {
    const layout = PangoCairo.create_layout(cr);
    const font = Pango.FontDescription.from_string(`Cantarell ${size}`);
    font.set_weight(weight);
    layout.set_font_description(font);
    layout.set_text(value, -1);
    const [ink] = layout.get_pixel_extents();
    setColor(cr, color);
    cr.moveTo(x - ink.x, Math.round(centerY - ink.y - ink.height / 2));
    PangoCairo.show_layout(cr, layout);
}

function drawPanelStatus(cr) {
    const color = {red: 238, green: 238, blue: 240};
    setColor(cr, color);
    cr.setLineWidth(2.2);
    cr.setLineCap(Cairo.LineCap.ROUND);

    cr.newSubPath();
    cr.arc(573, 34, 10, (5 * Math.PI) / 4, (7 * Math.PI) / 4);
    cr.stroke();
    cr.newSubPath();
    cr.arc(573, 34, 6, (5 * Math.PI) / 4, (7 * Math.PI) / 4);
    cr.stroke();
    cr.newSubPath();
    cr.arc(573, 34, 1.5, 0, 2 * Math.PI);
    cr.fill();

    cr.moveTo(602, 27);
    cr.lineTo(607, 27);
    cr.lineTo(613, 22);
    cr.lineTo(613, 42);
    cr.lineTo(607, 37);
    cr.lineTo(602, 37);
    cr.closePath();
    cr.stroke();
    cr.newSubPath();
    cr.arc(612, 32, 7, -Math.PI / 3, Math.PI / 3);
    cr.stroke();

    roundedRectangle(cr, 637, 23, 22, 18, 3);
    cr.stroke();
    cr.rectangle(660, 28, 3, 8);
    cr.fill();
    cr.rectangle(640, 26, 16, 12);
    cr.fill();

    centeredText(cr, '100%', 672, 32, 16, color);
}

function windowLine(cr, label, value, window, y) {
    const status = quotaStatus({[window]: value}, NOW);
    const color = paceColor(status) ?? {red: 178, green: 178, blue: 178};
    setColor(cr, color);
    cr.arc(80, y + 14, 6, 0, 2 * Math.PI);
    cr.fill();
    const used = displayPercent(value.usedPercent);
    const reference = ` (${used <= status.onTrackPercent ? '≤' : '>'}${formatPercent(status.onTrackPercent)})`;
    text(
        cr,
        `${label}  ${formatPercent(used)}${reference} · ${formatReset(value.resetsAt, NOW, window !== 'fiveHour')}`,
        102,
        y,
        20,
        {red: 205, green: 205, blue: 210},
    );
}

function providerLine(cr, label, y) {
    const color = {red: 238, green: 238, blue: 240};
    setColor(cr, color);
    cr.setLineWidth(3.2);
    cr.setLineCap(Cairo.LineCap.ROUND);
    cr.moveTo(46, y + 15);
    cr.lineTo(52, y + 21);
    cr.lineTo(64, y + 9);
    cr.stroke();
    text(cr, label, 78, y, 22, color);
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

cr.setSourceRGBA(0.3, 0.3, 0.32, 0.95);
roundedRectangle(cr, 375, 7, 169, 50, 25);
cr.fill();
for (const [prefix, quota, y] of [
    ['CX', codex, 22],
    ['CC', claude, 42],
]) {
    centeredText(
        cr,
        `${prefix} ${formatPercentages(quota)}`,
        397,
        y,
        15,
        paceColor(quotaStatus(quota, NOW)),
    );
}
drawPanelStatus(cr);

cr.setSourceRGBA(0, 0, 0, 0.32);
roundedRectangle(cr, 13, 81, 718, 473, 29);
cr.fill();
cr.setSourceRGBA(0.18, 0.18, 0.2, 0.985);
roundedRectangle(cr, 10, 77, 718, 471, 29);
cr.fillPreserve();
cr.setSourceRGBA(0.32, 0.32, 0.36, 0.55);
cr.setLineWidth(1.5);
cr.stroke();

providerLine(cr, 'Codex', 105);
windowLine(cr, '5-hour', codex.fiveHour, 'fiveHour', 156);
windowLine(cr, 'Weekly', codex.weekly, 'weekly', 204);

providerLine(cr, 'Claude', 281);
windowLine(cr, '5-hour', claude.fiveHour, 'fiveHour', 330);
windowLine(cr, 'Weekly', claude.weekly, 'weekly', 378);
windowLine(cr, 'Fable weekly', claude.fable, 'fable', 426);

for (const y of [254, 477]) {
    cr.setSourceRGBA(0.38, 0.38, 0.41, 0.5);
    cr.rectangle(48, y, 642, 1.5);
    cr.fill();
}
text(cr, `Refresh (${formatTime(Math.max(codex.updatedAt, claude.updatedAt))})`, 49, 502, 20, {
    red: 248,
    green: 248,
    blue: 250,
});

surface.writeToPNG(ARGV[0]);
