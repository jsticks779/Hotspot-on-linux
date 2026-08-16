// Linux Hotspot — a quick-settings tile for linux-hotspot.
//
// The tile talks to systemd, and a polkit rule shipped with the project makes
// start/stop password-free for a logged-in administrator. The password editor
// writes the shared config file, which the installer makes group-writable for
// the desktop user, so nothing here ever needs to run as root.
//
// https://github.com/jsticks779/Hotspot-on-linux

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Dialog from 'resource:///org/gnome/shell/ui/dialog.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import {QuickMenuToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const SERVICE = 'linux-hotspot.service';
const SETTINGS_FILE = '/etc/linux-hotspot/hotspot.conf';
const ICON = 'network-wireless-hotspot-symbolic';
const POLL_SECONDS = 5;

/** Run a command and hand (success, stdout, stderr) back to the caller. */
function run(argv, onDone) {
    try {
        const proc = Gio.Subprocess.new(argv,
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        proc.communicate_utf8_async(null, null, (p, res) => {
            try {
                const [, stdout, stderr] = p.communicate_utf8_finish(res);
                onDone?.(p.get_successful(), (stdout ?? '').trim(), (stderr ?? '').trim());
            } catch (e) {
                logError(e);
                onDone?.(false, '', `${e}`);
            }
        });
    } catch (e) {
        logError(e);
        onDone?.(false, '', `${e}`);
    }
}

function readSettings() {
    const settings = {SSID: 'hotspot', PASSPHRASE: ''};
    if (!GLib.file_test(SETTINGS_FILE, GLib.FileTest.EXISTS))
        return settings;
    try {
        const [ok, bytes] = GLib.file_get_contents(SETTINGS_FILE);
        if (ok) {
            for (const line of new TextDecoder().decode(bytes).split('\n')) {
                const match = line.match(/^(SSID|PASSPHRASE)=(.*)$/);
                if (match)
                    settings[match[1]] = match[2];
            }
        }
    } catch (e) {
        logError(e);
    }
    return settings;
}

/** Rewrite only the password line, so hand-written comments and overrides survive. */
function writePassword(password) {
    const [ok, bytes] = GLib.file_get_contents(SETTINGS_FILE);
    if (!ok)
        throw new Error(`cannot read ${SETTINGS_FILE}`);

    let text = new TextDecoder().decode(bytes);
    if (/^PASSPHRASE=.*$/m.test(text))
        text = text.replace(/^PASSPHRASE=.*$/m, `PASSPHRASE=${password}`);
    else
        text += `\nPASSPHRASE=${password}\n`;

    GLib.file_set_contents(SETTINGS_FILE, text);
    // file_set_contents writes a temp file and renames it, which resets the
    // mode — keep the Wi-Fi key away from other local users.
    Gio.File.new_for_path(SETTINGS_FILE).set_attribute_uint32(
        'unix::mode', 0o660, Gio.FileQueryInfoFlags.NONE, null);
}

const PasswordDialog = GObject.registerClass(
class PasswordDialog extends ModalDialog.ModalDialog {
    _init(onApply) {
        super._init({styleClass: 'prompt-dialog', destroyOnClose: true});

        this._onApply = onApply;
        const settings = readSettings();

        const content = new Dialog.MessageDialogContent({
            title: 'Hotspot password',
            description: `Network “${settings.SSID}” — 8 to 63 characters. ` +
                'Devices that are already connected will have to join again.',
        });
        this.contentLayout.add_child(content);

        this._entry = new St.Entry({
            style_class: 'search-entry',
            can_focus: true,
            x_expand: true,
            text: settings.PASSPHRASE,
        });
        this._entry.clutter_text.set_password_char('●');
        this._entry.set_secondary_icon(new St.Icon({icon_name: 'view-reveal-symbolic'}));
        this._entry.connect('secondary-icon-clicked', () => this._toggleReveal());
        this._entry.clutter_text.connect('activate', () => this._apply());
        content.add_child(this._entry);

        this._error = new St.Label({
            style_class: 'prompt-dialog-error-label',
            text: '',
            visible: false,
        });
        content.add_child(this._error);

        this.setButtons([
            {label: 'Cancel', action: () => this.close(), key: Clutter.KEY_Escape},
            {label: 'Apply', action: () => this._apply(), default: true},
        ]);

        this.setInitialKeyFocus(this._entry.clutter_text);
    }

    _toggleReveal() {
        const hidden = this._entry.clutter_text.get_password_char() !== '';
        this._entry.clutter_text.set_password_char(hidden ? '' : '●');
        this._entry.set_secondary_icon(new St.Icon({
            icon_name: hidden ? 'view-conceal-symbolic' : 'view-reveal-symbolic',
        }));
    }

    _apply() {
        const password = this._entry.get_text();
        if (password.length < 8 || password.length > 63) {
            this._error.text = 'The password must be 8 to 63 characters.';
            this._error.visible = true;
            return;
        }
        this.close();
        this._onApply(password);
    }
});

const HotspotToggle = GObject.registerClass(
class HotspotToggle extends QuickMenuToggle {
    _init() {
        super._init({
            title: 'Hotspot',
            subtitle: 'Off',
            iconName: ICON,
            toggleMode: false,   // the service decides what "on" means, not the click
        });

        this.menu.setHeader(ICON, 'Wi-Fi Hotspot', readSettings().SSID);
        this.menu.addAction('Change password…', () => this._changePassword());
        this.menu.connect('open-state-changed', (menu, isOpen) => {
            if (isOpen)
                this._refresh();
        });

        this.connect('clicked', () => this._toggleService());

        this._pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, POLL_SECONDS, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
        this.connect('destroy', () => {
            if (this._pollId) {
                GLib.source_remove(this._pollId);
                this._pollId = null;
            }
        });

        this._refresh();
    }

    _toggleService() {
        const start = !this.checked;
        this.subtitle = start ? 'Starting…' : 'Stopping…';
        this.reactive = false;

        run(['systemctl', start ? 'start' : 'stop', SERVICE], (ok, _out, err) => {
            this.reactive = true;
            if (!ok && start) {
                Main.notifyError('The hotspot did not start',
                    err || 'Run “linux-hotspot doctor” or check: journalctl -u linux-hotspot -n 20');
            }
            this._refresh();
        });
    }

    _changePassword() {
        new PasswordDialog(password => {
            try {
                writePassword(password);
            } catch (e) {
                logError(e);
                Main.notifyError('Could not save the password', `${e}`);
                return;
            }
            // A running hotspot has to restart before it uses the new key.
            run(['systemctl', 'is-active', SERVICE], (_ok, state) => {
                if (state !== 'active') {
                    Main.notify('Hotspot password changed');
                    return;
                }
                run(['systemctl', 'restart', SERVICE], (restarted, _o, err) => {
                    if (restarted)
                        Main.notify('Hotspot password changed', 'Devices must reconnect.');
                    else
                        Main.notifyError('Password saved, but the restart failed', err);
                    this._refresh();
                });
            });
        }).open();
    }

    _refresh() {
        run(['systemctl', 'is-active', SERVICE], (_ok, state) => {
            const active = state === 'active';
            const ssid = readSettings().SSID;
            this.checked = active;
            this.subtitle = active ? ssid : 'Off';
            this.menu.setHeader(ICON, 'Wi-Fi Hotspot', ssid);
        });
    }
});

const HotspotIndicator = GObject.registerClass(
class HotspotIndicator extends SystemIndicator {
    _init() {
        super._init();

        this._icon = this._addIndicator();
        this._icon.iconName = ICON;
        this._icon.visible = false;

        this.toggle = new HotspotToggle();
        this.toggle.connect('notify::checked',
            () => (this._icon.visible = this.toggle.checked));
        this.quickSettingsItems.push(this.toggle);
    }
});

export default class LinuxHotspotExtension extends Extension {
    enable() {
        this._indicator = new HotspotIndicator();
        const quickSettings = Main.panel.statusArea.quickSettings;
        quickSettings.addExternalIndicator(this._indicator);

        // Sit with the other network tiles instead of at the bottom of the menu.
        try {
            const grid = quickSettings.menu._grid;
            const networkItems = (quickSettings._network?.quickSettingsItems ?? [])
                .filter(item => item.get_parent() === grid);
            if (networkItems.length)
                grid.set_child_above_sibling(this._indicator.toggle, networkItems.at(-1));
        } catch (e) {
            logError(e);
        }
    }

    disable() {
        this._indicator?.quickSettingsItems.forEach(item => item.destroy());
        this._indicator?.destroy();
        this._indicator = null;
    }
}
