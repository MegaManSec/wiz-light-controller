import customtkinter as ctk
import tkinter as tk
from tkinter import colorchooser, messagebox
import colorsys, sys, os, math, json, socket, time, threading
from PIL import Image, ImageDraw, ImageTk, ImageFilter

def resource_path(relative_path):
    try:
        base_path = sys._MEIPASS
    except Exception:
        base_path = os.path.abspath(".")

    return os.path.join(base_path, relative_path)

if sys.platform == "win32":
    try:
        import ctypes
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(
            "Keks.WizLightController"
        )
    except Exception:
        pass

APP_DIR = os.path.join(
    os.getenv("LOCALAPPDATA") or os.getcwd(),
    "KeksWizLightController",
)
IP_STORE_FILE = os.path.join(APP_DIR, "last_ip.txt")
PRESETS_FILE = os.path.join(APP_DIR, "presets.json")
SETTINGS_FILE = os.path.join(APP_DIR, "settings.json")
SAVED_LIGHTS_FILE = os.path.join(APP_DIR, "saved_lights.json")

SLIDER_BG_COLOR = "#333333"
STATE_CONNECTED_COLOR = "#4ade80"
STATE_DISCONNECTED_COLOR = "#f87171"

# ---------- Settings State ----------
DEFAULT_ACCENT = "#7b2cbf"
DEFAULT_HIGHLIGHT = "#590A9D"
DEFAULT_AUTO_SYNC = True

SETTINGS_FILE = os.path.join(APP_DIR, "settings.json")

accent_color = DEFAULT_ACCENT
highlight_color = DEFAULT_HIGHLIGHT
discover_stop_flag = threading.Event()
auto_sync_enabled = DEFAULT_AUTO_SYNC

def hex_add_24(hex_color):
    r = min(255, int(hex_color[1:3], 16) + 24)
    g = min(255, int(hex_color[3:5], 16) + 24)
    b = min(255, int(hex_color[5:7], 16) + 24)
    return f"#{r:02x}{g:02x}{b:02x}"

def update_hex_preview(entry_var, preview_widget, fallback):
    value = entry_var.get().strip()

    color = sanitize_hex_color(value, fallback)
    try:
        preview_widget.configure(fg_color=color)
    except Exception:
        pass

def sanitize_hex_color(value, fallback):
    if not isinstance(value, str):
        return fallback

    value = value.strip()

    if not value.startswith("#"):
        value = "#" + value

    if len(value) != 7:
        return fallback

    try:
        int(value[1:], 16)
    except ValueError:
        return fallback

    return value.lower()

def is_valid_hex_color(value):
    if not isinstance(value, str):
        return False

    value = value.strip()
    if value.startswith("#"):
        value = value[1:]

    if len(value) != 6:
        return False

    try:
        int(value, 16)
        return True
    except ValueError:
        return False

def load_settings():
    global accent_color, highlight_color, auto_sync_enabled
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)

                accent_color = sanitize_hex_color(
                    data.get("accent"),
                    DEFAULT_ACCENT,
                )

                highlight_color = sanitize_hex_color(
                    data.get("highlight"),
                    DEFAULT_HIGHLIGHT,
                )

                auto_sync_enabled = bool(
                    data.get("auto_sync", DEFAULT_AUTO_SYNC)
                )
    except Exception:
        pass

def save_settings():
    try:
        os.makedirs(APP_DIR, exist_ok=True)
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "accent": accent_color,
                    "highlight": highlight_color,
                    "auto_sync": auto_sync_enabled,
                },
                f,
                indent=2,
            )
    except Exception:
        pass

def load_saved_lights():
    if not os.path.exists(SAVED_LIGHTS_FILE):
        return {}
    try:
        with open(SAVED_LIGHTS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def save_saved_lights(data):
    os.makedirs(APP_DIR, exist_ok=True)
    with open(SAVED_LIGHTS_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

WIZ_PORT = 38899
DEFAULT_IP = ""

presets = {}

discover_icon = ctk.CTkImage(
    light_image=Image.open(resource_path("assets/discover.png")),
    dark_image=Image.open(resource_path("assets/discover.png")),
    size=(20, 20),
)

discover_icon_hover = ctk.CTkImage(
    light_image=Image.open(resource_path("assets/discover_hover.png")),
    dark_image=Image.open(resource_path("assets/discover_hover.png")),
    size=(20, 20),
)

settings_icon = ctk.CTkImage(
    light_image=Image.open(resource_path("assets/settings.png")),
    dark_image=Image.open(resource_path("assets/settings.png")),
    size=(24, 24)
)

settings_icon_hover = ctk.CTkImage(
    light_image=Image.open(resource_path("assets/settings_hover.png")),
    dark_image=Image.open(resource_path("assets/settings_hover.png")),
    size=(24, 24),
)

ip_help_icon = ctk.CTkImage(
    light_image=Image.open(resource_path("assets/help.png")),
    dark_image=Image.open(resource_path("assets/help.png")),
    size=(20, 20),
)

ip_help_icon_hover = ctk.CTkImage(
    light_image=Image.open(resource_path("assets/help_hover.png")),
    dark_image=Image.open(resource_path("assets/help_hover.png")),
    size=(20, 20),
)

# ---- State ----
current_rgb = (255, 255, 255)
current_brightness = 100
current_state = True
current_temp = 4000
current_mode = "rgb"
is_syncing = False
connected = False
selected_preset_name = None
updating_color_ui = False
user_editing_color = False
hex_update_job = None
wheel_drag_active = False
wheel_dragging = False
hsv_authoritative = True
HUE_SLIDER_HEIGHT = 16

# ---- Authoritative device color ----
device_rgb = (255, 255, 255)
device_temp = 4000
brightness_source_rgb = (255, 255, 255)

# Resolve CTk frame background color for current theme
frame_bg = ctk.ThemeManager.theme["CTkFrame"]["fg_color"]
# ---- HSV State ----
current_h = 0.0
current_s = 0.0
current_v = 1.0

def load_last_ip():
    global DEFAULT_IP
    try:
        if os.path.exists(IP_STORE_FILE):
            with open(IP_STORE_FILE, "r", encoding="utf-8") as f:
                ip = f.read().strip()
                if ip:
                    DEFAULT_IP = ip
                    print(f"[IP] Loaded last IP: {DEFAULT_IP}")
    except OSError:
        print("[IP] Failed to load last IP, using default.")

def save_last_ip(ip: str):
    ip = (ip or "").strip()
    if not ip:
        return
    try:
        os.makedirs(APP_DIR, exist_ok=True)
        with open(IP_STORE_FILE, "w", encoding="utf-8") as f:
            f.write(ip)
        print(f"[IP] Saved last IP to: {IP_STORE_FILE}")
    except OSError as e:
        print(f"[IP] Failed to save last IP: {e}")
       
RGB_STORE_FILE = os.path.join(APP_DIR, "last_rgb.json")

def save_last_rgb(rgb):
    try:
        os.makedirs(APP_DIR, exist_ok=True)
        with open(RGB_STORE_FILE, "w", encoding="utf-8") as f:
            json.dump(
                {"r": rgb[0], "g": rgb[1], "b": rgb[2]},
                f
            )
            print(f"[RGB] Saved RGB values to {RGB_STORE_FILE} with values {rgb}.")
    except Exception as e:
        print(f"[RGB] Failed to save last RGB: {e}")

def load_last_rgb():
    try:
        if os.path.exists(RGB_STORE_FILE):
            with open(RGB_STORE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                print(f"[RGB] Loaded RGB values from last_rgb.json with values ({data.get("r", 255)}, {data.get("g", 255)}, {data.get("b", 255)}).")
                return (
                    int(data.get("r", 255)),
                    int(data.get("g", 255)),
                    int(data.get("b", 255)),
                )
    except Exception as e:
        print(f"[RGB] Failed to load last RGB: {e}")

    return (255, 255, 255)
       
def load_presets():
    global presets
    try:
        if os.path.exists(PRESETS_FILE):
            with open(PRESETS_FILE, "r", encoding="utf-8") as f:
                presets = json.load(f)
                print(f"[PRESETS] Loaded presets from {PRESETS_FILE}")
                return
    except Exception as e:
        print(f"[PRESETS] Failed to load presets: {e}")

    presets = {
        "rgb": {
            "Red": {"mode": "rgb", "r": 255, "g": 0, "b": 0, "brightness": 100},
            "Green": {"mode": "rgb", "r": 0, "g": 255, "b": 0, "brightness": 100},
            "Blue": {"mode": "rgb", "r": 0, "g": 0, "b": 255, "brightness": 100},
            "Purple": {"mode": "rgb", "r": 128, "g": 0, "b": 255, "brightness": 100},
            "Sunset": {"mode": "rgb", "r": 255, "g": 120, "b": 40, "brightness": 100},
            "Aqua": {"mode": "rgb", "r": 0, "g": 255, "b": 255, "brightness": 100},
        },
        "white": {
            "Full White": {"mode": "white", "temp": 6500, "brightness": 100},
            "Warmish": {"mode": "white", "temp": 4000, "brightness": 100},
            "Relax": {"mode": "white", "temp": 3000, "brightness": 100},
            "Full Warm": {"mode": "white", "temp": 2200, "brightness": 100},
            "Dim Relax": {"mode": "white", "temp": 2700, "brightness": 40},
            "Dim White": {"mode": "white", "temp": 6500, "brightness": 40},
        },
    }

    save_presets()

def save_presets():
    try:
        os.makedirs(APP_DIR, exist_ok=True)
        with open(PRESETS_FILE, "w", encoding="utf-8") as f:
            json.dump(presets, f, indent=2)
        print(f"[PRESETS] Saved presets to {PRESETS_FILE}")
    except Exception as e:
        print(f"[PRESETS] Failed to save presets: {e}")

ip_var = None

DEBOUNCE_MS = 250
pending_after_id = None
pending_params = None
root = None

def clear_preset_selection():
    global selected_preset_name
    if selected_preset_name is not None:
        selected_preset_name = None
        rebuild_preset_buttons()

def show_no_ip_dialog():
    dialog = ctk.CTkToplevel(root)
    dialog.title("First Launch Dialog")
    apply_window_icon(dialog)
    dialog.resizable(False, False)
    center_window(dialog, root, 360, 260)
    dialog.transient(root)
    dialog.lift()


    ctk.CTkLabel(
        dialog,
        text="Welcome!",
        font=ctk.CTkFont(weight="bold"),
    ).pack(pady=(20, 8))

    ctk.CTkLabel(
        dialog,
        text="This is likely your first time launching this app. \nTo control WiZ lights, your computer needs to be connected to the same network as the light itself. \n\nTo scan for WiZ lights on your network, click on the Wi-Fi icon next to the WiZ IP text box. \n\nClick on the question mark icon for a Help & Guide section.",
        wraplength=300,
        justify="center",
    ).pack(pady=(0, 14))

    btn_frame = ctk.CTkFrame(dialog, fg_color="transparent")
    btn_frame.pack(pady=8)

    ctk.CTkButton(
        btn_frame,
        text="Scan for Lights",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=lambda: (dialog.destroy(), open_discovery_dialog()),
    ).pack(side="left", padx=6)

    ctk.CTkButton(
        btn_frame,
        text="OK",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=dialog.destroy,
    ).pack(side="left", padx=6)

def send_command(params: dict):
    """Send a setPilot command with the given params to the light."""
    ip = ip_var.get().strip() if ip_var is not None else DEFAULT_IP
    if not ip:
        messagebox.showerror("Error", "Please enter the WiZ light IP address.")
        return

    payload = {
        "method": "setPilot",
        "params": params,
    }

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(1)
        data = json.dumps(payload).encode("utf-8")
        sock.sendto(data, (ip, WIZ_PORT))
        sock.close()
    except Exception as e:
        messagebox.showerror("Network Error", f"Failed to send command:\n{e}")

def send_with_retry(params, attempts=3, interval=120):
    if not connected:
        pass

    def attempt(i):
        if i >= attempts:
            return

        send_command(params)

        root.after(interval, lambda: attempt(i + 1))

    attempt(0)

def format_mac(mac: str):
    if not mac or len(mac) != 12:
        return mac
    return ":".join(mac[i:i+2] for i in range(0, 12, 2)).upper()

def schedule_send(params: dict):

    global pending_after_id, pending_params

    if "temp" in params:
        desc = f"WHITE({params.get('temp', '?')}K)"
    elif "r" in params:
        desc = f"RGB({params.get('r','?')},{params.get('g','?')},{params.get('b','?')})"
    else:
        desc = f"STATE({params.get('state')})"

    brightness = params.get("dimming", "no-brightness")
    print(f"[DEBOUNCE] Scheduled: {desc} Brightness={brightness}")

    pending_params = params

    if root is None:
        return

    if pending_after_id is not None:
        try:
            root.after_cancel(pending_after_id)
        except Exception:
            pass

    pending_after_id = root.after(DEBOUNCE_MS, _flush_send)

def animate_label_change(label, old, new, suffix="", steps=10, duration=200, slider=None):
    """
    Smoothly animate a numeric value from old -> new.

    If slider is provided, it animates both:
      - the label text
      - the slider position (using slider.set(...))
    """
    try:
        old_num = int(old)
    except (TypeError, ValueError):
        old_num = new
    try:
        new_num = int(new)
    except (TypeError, ValueError):
        label.configure(text=f"{new}{suffix}")
        if slider is not None:
            slider.set(new)
        return

    if old_num == new_num or steps <= 0:
        label.configure(text=f"{new_num}{suffix}")
        if slider is not None:
            slider.set(new_num)
        return

    diff = new_num - old_num
    step_varue = diff / steps
    step_time = max(1, duration // steps)

    def step(i, value):
        if i >= steps:
            label.configure(text=f"{new_num}{suffix}")
            if slider is not None:
                slider.set(new_num)
            return

        label.configure(text=f"{int(round(value))}{suffix}")
        if slider is not None:
            slider.set(value)

        if root is not None:
            root.after(step_time, step, i + 1, value + step_varue)

    step(0, float(old_num))

def animate_brightness_to(target, duration=180):
    global current_brightness
    start = current_brightness
    delta = target - start
    steps = max(1, int(duration / 16))
    step = 0

    def tick():
        nonlocal step
        if step >= steps:
            current_brightness = target
            brightness_varue_label.configure(text=f"{current_brightness}%")
            redraw_brightness_slider()
            return

        t = step / steps
        current_brightness = int(start + delta * t)

        brightness_varue_label.configure(text=f"{current_brightness}%")
        redraw_brightness_slider()

        step += 1
        root.after(16, tick)

    tick()

def _flush_send():
    global pending_after_id, pending_params

    if pending_params is not None:
        params = pending_params

        if "temp" in params:
            desc = f"WHITE({params.get('temp','?')}K)"
        elif "r" in params:
            desc = (
                f"RGB({params.get('r','?')},"
                f"{params.get('g','?')},"
                f"{params.get('b','?')})"
            )
        else:
            desc = f"STATE({params.get('state')})"

        brightness = params.get("dimming", "no-brightness")
        print(f"[SENT] {desc} Brightness={brightness}")

        send_with_retry(params)

    pending_after_id = None
    pending_params = None

def save_current_preset():
    dialog = ctk.CTkToplevel(root)
    dialog.title("Save Preset")
    apply_window_icon(dialog)
    center_window(dialog, root, 360, 360)
    dialog.grab_set()

    ctk.CTkLabel(
        dialog,
        text=f"Overwrite {current_mode.upper()} preset:",
        font=ctk.CTkFont(size=14, weight="bold"),
    ).pack(pady=(15, 5))

    selected = tk.StringVar(value=None)

    list_frame = ctk.CTkFrame(dialog)
    list_frame.pack(padx=15, pady=10, fill="x")

    for name in presets[current_mode].keys():
        ctk.CTkRadioButton(
            list_frame,
            text=name,
            variable=selected,
            value=name,
        ).pack(anchor="w", padx=10, pady=2)

    ctk.CTkLabel(
        dialog,
        text="New name (optional):"
    ).pack(pady=(10, 2))

    name_entry = ctk.CTkEntry(dialog, width=240)
    name_entry.pack(pady=4)

    def confirm():
        slot = selected.get()
        if not slot:
            messagebox.showinfo("Select preset", "Choose a preset to overwrite.")
            return

        new_name = name_entry.get().strip() or slot

        data = (
            {
                "mode": "rgb",
                "r": current_rgb[0],
                "g": current_rgb[1],
                "b": current_rgb[2],
                "brightness": current_brightness,
            }
            if current_mode == "rgb"
            else {
                "mode": "white",
                "temp": current_temp,
                "brightness": current_brightness,
            }
        )

        presets[current_mode].pop(slot)
        presets[current_mode][new_name] = data

        global selected_preset_name
        selected_preset_name = new_name

        save_presets()
        rebuild_preset_buttons()
        dialog.destroy()

    ctk.CTkButton(
        dialog,
        text="Save",
        command=confirm,
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
    ).pack(pady=15)

def get_pilot():
    """Query current state from the light (getPilot). Returns result dict or None."""
    ip = ip_var.get().strip() if ip_var is not None else DEFAULT_IP
    if not ip:
        return None

    payload = {
        "method": "getPilot",
        "params": {},
    }

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(1)
        data = json.dumps(payload).encode("utf-8")
        sock.sendto(data, (ip, WIZ_PORT))

        resp, _ = sock.recvfrom(4096)
        sock.close()
        decoded = json.loads(resp.decode("utf-8"))
        return decoded.get("result", {})
    except Exception:
        return None

def discover_wiz_lights(on_found, on_done, timeout=2.0, attempts=3):
    def worker():
        seen = set()
        found_any = False

        discover_stop_flag.clear()

        for _ in range(attempts):
            if discover_stop_flag.is_set():
                break

            payload = json.dumps({
                "method": "getSystemConfig",
                "params": {}
            }).encode("utf-8")

            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.settimeout(timeout)

            try:
                sock.sendto(payload, ("255.255.255.255", WIZ_PORT))

                start = time.time()
                while time.time() - start < timeout:
                    if discover_stop_flag.is_set():
                        break

                    try:
                        data, addr = sock.recvfrom(4096)
                        decoded = json.loads(data.decode("utf-8"))
                        result = decoded.get("result", {})
                        mac = result.get("mac")
                        name = result.get("moduleName") or result.get("mac")
                        ip = addr[0]

                        if name and ip not in seen:
                            seen.add(ip)
                            found_any = True
                            root.after(0, lambda n=name, i=ip, m=mac: on_found(n, i, m))

                    except socket.timeout:
                        break
                    except Exception:
                        continue
            finally:
                sock.close()

        root.after(0, lambda: on_done(found_any))

    threading.Thread(target=worker, daemon=True).start()

def debounce(func, delay=250):
    timer = {"id": None}

    def wrapped(*args):
        if timer["id"]:
            root.after_cancel(timer["id"])
        timer["id"] = root.after(delay, lambda: func(*args))

    return wrapped

def update_state_label(connected: bool):
    
    if connected:
        state_label.configure(
            text="State: Connected",
            text_color=STATE_CONNECTED_COLOR
        )
    else:
        state_label.configure(
            text="State: Disconnected",
            text_color=STATE_DISCONNECTED_COLOR
        )

def set_power_ui(is_on: bool):
    global current_state

    current_state = is_on
    power_segment.set("ON" if is_on else "OFF")

    if is_on:
        power_segment.configure(
            selected_color=accent_color,
            selected_hover_color=hex_add_24(accent_color),
        )

        mode_frame.pack(side="left", padx=(18, 0))

        update_control_states()
        rebuild_preset_buttons()

    else:
        power_segment.configure(
            selected_color="#FF0000",
            selected_hover_color="#FF3232",
        )

        mode_frame.pack_forget()

        preset_label.pack_forget()
        preset_frame.pack_forget()
        save_preset_button.pack_forget()
        color_picker_frame.pack_forget()
        temp_frame.pack_forget()
        brightness_frame.pack_forget()

        root.geometry("609x128")

def generate_color_wheel(size=240):
    scale = 2
    s = size * scale
    radius = s // 2

    img = Image.new("RGBA", (s, s))
    draw = ImageDraw.Draw(img)

    for y in range(s):
        for x in range(s):
            dx = x - radius
            dy = y - radius
            dist = math.sqrt(dx*dx + dy*dy)

            if dist <= radius:
                h = (math.atan2(dy, dx) + math.pi) / (2 * math.pi)  # This code is gonna kill me
                s_val = dist / radius
                r, g, b = colorsys.hsv_to_rgb(h, s_val, 1.0)
                draw.point(
                    (x, y),
                    (int(r * 255), int(g * 255), int(b * 255), 255) # I HATE MATH
                )

    mask = Image.new("L", (s, s), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.ellipse((0, 0, s, s), fill=255)

    img.putalpha(mask)

    img = img.resize((size, size), Image.LANCZOS)

    return ImageTk.PhotoImage(img)

def apply_window_icon(window):
    def _apply():
        try:
            window.iconbitmap(resource_path("assets/app_icon.ico"))
        except Exception:
            try:
                icon_image = tk.PhotoImage(
                    file=resource_path("assets/app_icon.png")
                )
                window.iconphoto(True, icon_image)
                window._icon_ref = icon_image
            except Exception:
                pass

    _apply()

    def _reinforce():
        _apply()
        window.after(50, _apply)
        window.after(150, _apply)
        window.after(300, _apply)

    window.bind("<Map>", lambda e: _reinforce())

wheel_marker = None
dragging_wheel = False

def resolve_ctk_color(color):
    if isinstance(color, (list, tuple)):
        return color[0] if ctk.get_appearance_mode() == "Light" else color[1]
    return color

def commit_rgb_preview():
    save_last_rgb(current_rgb)

def update_color_preview():
    wheel_canvas.delete("preview")

    r, g, b = current_rgb
    color = (r, g, b, 255)

    PAD = 10
    RADIUS = 14

    cx = wheel_size - PAD - RADIUS
    cy = PAD + RADIUS

    scale = 3
    radius = RADIUS * scale
    size = radius * 2 + 4

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    draw.ellipse(
        (2, 2, size - 2, size - 2),
        fill=color,
        outline=(17, 17, 17, 255),
        width=2 * scale,
    )
    img = img.resize(
        (RADIUS * 2, RADIUS * 2), # this math omg
        Image.LANCZOS
    )
    preview_img = ImageTk.PhotoImage(img)

    wheel_canvas.preview_img = preview_img

    wheel_canvas.create_image(
        cx,
        cy,
        image=preview_img,
        tags="preview"
    )

def draw_brightness_thumb(value):
    global brightness_thumb

    width = brightness_canvas.winfo_width()
    if width <= 1:
        return

    thumb_radius = 6
    min_x = thumb_radius
    max_x = width - thumb_radius
    x = min_x + (value / 100) * (max_x - min_x)

    if brightness_thumb:
        brightness_canvas.delete(brightness_thumb)

    scale = 2
    r = thumb_radius * scale
    size = r * 2 + 2

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse(
        (1, 1, size - 2, size - 2),
        fill=(255, 255, 255, 255),
        outline=(0, 0, 0, 255),
        width=2 * scale,
    )

    img = img.resize((thumb_radius * 2, thumb_radius * 2), Image.LANCZOS)
    thumb_img = ImageTk.PhotoImage(img)
    brightness_canvas.thumb_img = thumb_img

    brightness_thumb = brightness_canvas.create_image(
        int(x),
        HUE_SLIDER_HEIGHT // 2,
        image=thumb_img
    )

def draw_temp_thumb(value):
    global temp_thumb

    width = temp_canvas.winfo_width()
    if width <= 1:
        return

    thumb_radius = 6
    min_x = thumb_radius
    max_x = width - thumb_radius

    t = (value - 2200) / (6500 - 2200)
    x = min_x + t * (max_x - min_x)

    if temp_thumb:
        temp_canvas.delete(temp_thumb)

    scale = 2
    r = thumb_radius * scale
    size = r * 2 + 2

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse(
        (1, 1, size - 2, size - 2),
        fill=(255, 255, 255, 255),
        outline=(0, 0, 0, 255),
        width=2 * scale,
    )

    img = img.resize((thumb_radius * 2, thumb_radius * 2), Image.LANCZOS)
    thumb_img = ImageTk.PhotoImage(img)
    temp_canvas.thumb_img = thumb_img

    temp_thumb = temp_canvas.create_image(
        int(x),
        HUE_SLIDER_HEIGHT // 2,
        image=thumb_img
    )

def redraw_temp_slider():
    temp_canvas.delete("all")

    width = temp_canvas.winfo_width()
    if width <= 1:
        return

    gradient = generate_temp_gradient(width, HUE_SLIDER_HEIGHT)
    temp_canvas.gradient_img = gradient
    temp_canvas.create_image(0, 0, anchor="nw", image=gradient)

    draw_temp_thumb(current_temp)

def redraw_brightness_slider():
    brightness_canvas.delete("all")

    width = brightness_canvas.winfo_width()
    if width <= 1:
        return

    r, g, b = brightness_source_rgb

    gradient = generate_brightness_gradient(
        width,
        HUE_SLIDER_HEIGHT,
        r, g, b
    )

    brightness_canvas.gradient_img = gradient
    brightness_canvas.create_image(0, 0, anchor="nw", image=gradient)

    draw_brightness_thumb(current_brightness)

def on_temp_canvas_event(event):
    global current_temp, device_temp, selected_preset_name
    clear_preset_selection()

    if current_mode != "white":
        return

    width = temp_canvas.winfo_width()
    if width <= 1:
        return

    x = min(max(event.x, 0), width - 1)
    t = x / (width - 1)

    raw_temp = 2200 + t * (6500 - 2200)

    snapped_temp = int(round(raw_temp / 100) * 100)
    snapped_temp = max(2200, min(6500, snapped_temp))

    if snapped_temp == current_temp:
        return

    current_temp = snapped_temp
    device_temp = current_temp
    selected_preset_name = None

    temp_varue_label.configure(text=f"{current_temp}K")

    redraw_temp_slider()
    update_brightness_source_from_device()
    redraw_brightness_slider()
    update_light()

def on_brightness_canvas_event(event):
    global current_brightness, selected_preset_name
    clear_preset_selection()

    width = brightness_canvas.winfo_width()
    if width <= 1:
        return

    x = min(max(event.x, 0), width - 1)
    current_brightness = int((x / (width - 1)) * 100)

    selected_preset_name = None
    brightness_varue_label.configure(text=f"{current_brightness}%")

    update_brightness_source_from_device()
    redraw_brightness_slider()
    update_light()
    if current_mode == "white":
        redraw_temp_slider()

def generate_rgb_gradient(width, height, channel, r, g, b):
    scale = 2
    w, h_px = width * scale, height * scale

    img = Image.new("RGBA", (w, h_px))
    draw = ImageDraw.Draw(img)

    for x in range(w):
        t = x / (w - 1)

        if channel == "r":
            rr = int(t * 255)
            gg, bb = g, b
        elif channel == "g":
            rr, gg = r, int(t * 255)
            bb = b
        else: 
            rr, gg = r, g
            bb = int(t * 255)

        draw.line(
            [(x, 0), (x, h_px)],
            fill=(rr, gg, bb, 255),
        )

    mask = Image.new("L", (w, h_px), 0)
    mdraw = ImageDraw.Draw(mask)
    radius = h_px // 2
    mdraw.rounded_rectangle((0, 0, w, h_px), radius=radius, fill=255)

    img.putalpha(mask)
    img = img.resize((width, height), Image.LANCZOS)

    return ImageTk.PhotoImage(img)

def generate_hue_gradient(width, height):
    scale = 2
    w, h = width * scale, height * scale

    img = Image.new("RGBA", (w, h))
    draw = ImageDraw.Draw(img)

    for x in range(w):
        hue = x / (w - 1)
        r, g, b = colorsys.hsv_to_rgb(hue, 1.0, 1.0)
        draw.line(
            [(x, 0), (x, h)],
            fill=(int(r * 255), int(g * 255), int(b * 255), 255),
        )

    mask = Image.new("L", (w, h), 0)
    mdraw = ImageDraw.Draw(mask)
    radius = h // 2
    mdraw.rounded_rectangle(
        (0, 0, w, h),
        radius=radius,
        fill=255,
    )

    img.putalpha(mask)

    img = img.resize((width, height), Image.LANCZOS)

    return ImageTk.PhotoImage(img)

def generate_saturation_gradient(width, height, h, v):
    scale = 2
    w, h_px = width * scale, height * scale

    img = Image.new("RGBA", (w, h_px))
    draw = ImageDraw.Draw(img)

    for x in range(w):
        s = x / (w - 1)
        r, g, b = colorsys.hsv_to_rgb(h, s, v)
        draw.line(
            [(x, 0), (x, h_px)],
            fill=(int(r * 255), int(g * 255), int(b * 255), 255),
        )

    mask = Image.new("L", (w, h_px), 0)
    mdraw = ImageDraw.Draw(mask)
    radius = h_px // 2
    mdraw.rounded_rectangle((0, 0, w, h_px), radius=radius, fill=255)

    img.putalpha(mask)
    img = img.resize((width, height), Image.LANCZOS)
    return ImageTk.PhotoImage(img)

def generate_value_gradient(width, height, h, s):
    scale = 2
    w, h_px = width * scale, height * scale

    img = Image.new("RGBA", (w, h_px))
    draw = ImageDraw.Draw(img)

    for x in range(w):
        v = x / (w - 1)
        r, g, b = colorsys.hsv_to_rgb(h, s, v)
        draw.line(
            [(x, 0), (x, h_px)],
            fill=(int(r * 255), int(g * 255), int(b * 255), 255),
        )

    mask = Image.new("L", (w, h_px), 0)
    mdraw = ImageDraw.Draw(mask)
    radius = h_px // 2
    mdraw.rounded_rectangle((0, 0, w, h_px), radius=radius, fill=255)

    img.putalpha(mask)
    img = img.resize((width, height), Image.LANCZOS)
    return ImageTk.PhotoImage(img)

def kelvin_to_rgb(temp_k: int):
    """
    Convert Kelvin temperature to RGB.
    Approximation is more than good enough for UI gradients.
    """
    t = temp_k / 100.0

    if t <= 66:
        r = 255
        g = 99.4708025861 * math.log(t) - 161.1195681661
        b = 0 if t <= 19 else 138.5177312231 * math.log(t - 10) - 305.0447927307
    else:
        r = 329.698727446 * ((t - 60) ** -0.1332047592)
        g = 288.1221695283 * ((t - 60) ** -0.0755148492)
        b = 255

    return (
        int(max(0, min(255, r))),
        int(max(0, min(255, g))),
        int(max(0, min(255, b))),
    )

def update_brightness_source_from_device():
    global brightness_source_rgb

    if current_mode == "rgb":
        brightness_source_rgb = device_rgb
    else:
        brightness_source_rgb = kelvin_to_rgb(device_temp)

def generate_brightness_gradient(width, height, r, g, b):
    scale = 2
    w, h_px = width * scale, height * scale

    bg_r, bg_g, bg_b = (43, 43, 43)

    img = Image.new("RGBA", (w, h_px))
    draw = ImageDraw.Draw(img)

    for x in range(w):
        t = x / (w - 1)
        rr = int(bg_r + (r - bg_r) * t)
        gg = int(bg_g + (g - bg_g) * t)
        bb = int(bg_b + (b - bg_b) * t)

        draw.line(
            [(x, 0), (x, h_px)],
            fill=(rr, gg, bb, 255),
        )

    mask = Image.new("L", (w, h_px), 0)
    mdraw = ImageDraw.Draw(mask)
    radius = h_px // 2
    mdraw.rounded_rectangle((0, 0, w, h_px), radius=radius, fill=255)

    img.putalpha(mask)
    img = img.resize((width, height), Image.LANCZOS)

    return ImageTk.PhotoImage(img)

def generate_temp_gradient(width, height):
    """
    2200K → 6500K temperature gradient
    """
    scale = 2
    w, h_px = width * scale, height * scale

    cold_r, cold_g, cold_b = kelvin_to_rgb(2200)
    hot_r, hot_g, hot_b = (255, 255, 255)

    img = Image.new("RGBA", (w, h_px))
    draw = ImageDraw.Draw(img)

    for x in range(w):
        t = x / (w - 1)
        rr = int(cold_r + (hot_r - cold_r) * t)
        gg = int(cold_g + (hot_g - cold_g) * t)
        bb = int(cold_b + (hot_b - cold_b) * t)

        draw.line([(x, 0), (x, h_px)], fill=(rr, gg, bb, 255))

    mask = Image.new("L", (w, h_px), 0)
    mdraw = ImageDraw.Draw(mask)
    radius = h_px // 2
    mdraw.rounded_rectangle((0, 0, w, h_px), radius=radius, fill=255)

    img.putalpha(mask)
    img = img.resize((width, height), Image.LANCZOS)

    return ImageTk.PhotoImage(img)

def draw_rgb_thumb(canvas, value):
    canvas.delete("thumb")

    width = canvas.winfo_width()
    if width <= 1:
        return

    thumb_radius = 6
    min_x = thumb_radius
    max_x = width - thumb_radius
    x = min_x + (value / 255) * (max_x - min_x)

    scale = 2
    r = thumb_radius * scale
    size = r * 2 + 2

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    draw.ellipse(
        (1, 1, size - 2, size - 2),
        fill=(255, 255, 255, 255),
        outline=(0, 0, 0, 255),
        width=2 * scale,
    )

    img = img.resize(
        (thumb_radius * 2, thumb_radius * 2),
        Image.LANCZOS
    )

    thumb_img = ImageTk.PhotoImage(img)

    if not hasattr(canvas, "thumb_imgs"):
        canvas.thumb_imgs = []
    canvas.thumb_imgs.append(thumb_img)

    canvas.create_image(
        int(x),
        HUE_SLIDER_HEIGHT // 2,
        image=thumb_img,
        tags="thumb"
    )

def draw_hue_thumb(h):
    global hue_thumb

    width = hue_canvas.winfo_width()
    if width <= 1:
        return

    thumb_radius = 6
    min_x = thumb_radius
    max_x = width - thumb_radius

    x = min_x + h * (max_x - min_x)

    if hue_thumb:
        hue_canvas.delete(hue_thumb)

    scale = 2
    radius = thumb_radius * scale
    size = radius * 2 + 2

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse(
        (1, 1, size - 2, size - 2),
        fill=(255, 255, 255, 255),
        outline=(0, 0, 0, 255),
        width=2 * scale,
    )

    img = img.resize(
        (thumb_radius * 2, thumb_radius * 2),
        Image.LANCZOS
    )

    thumb_img = ImageTk.PhotoImage(img)
    hue_canvas.thumb_img = thumb_img  # prevent GC

    hue_thumb = hue_canvas.create_image(
        int(x),
        HUE_SLIDER_HEIGHT // 2,
        image=thumb_img
    )

def draw_sat_thumb(s):
    global sat_thumb

    width = sat_canvas.winfo_width()
    if width <= 1:
        return

    thumb_radius = 6
    min_x = thumb_radius
    max_x = width - thumb_radius
    x = min_x + s * (max_x - min_x)

    if sat_thumb:
        sat_canvas.delete(sat_thumb)

    scale = 2
    r = thumb_radius * scale
    size = r * 2 + 2

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse(
        (1, 1, size - 2, size - 2),
        fill=(255, 255, 255, 255),
        outline=(0, 0, 0, 255),
        width=2 * scale,
    )

    img = img.resize((thumb_radius * 2, thumb_radius * 2), Image.LANCZOS)
    thumb_img = ImageTk.PhotoImage(img)
    sat_canvas.thumb_img = thumb_img

    sat_thumb = sat_canvas.create_image(
        int(x),
        HUE_SLIDER_HEIGHT // 2,
        image=thumb_img
    )

def draw_val_thumb(v):
    global val_thumb

    width = val_canvas.winfo_width()
    if width <= 1:
        return

    thumb_radius = 6
    min_x = thumb_radius
    max_x = width - thumb_radius
    x = min_x + v * (max_x - min_x)

    if val_thumb:
        val_canvas.delete(val_thumb)

    scale = 2
    r = thumb_radius * scale
    size = r * 2 + 2

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse(
        (1, 1, size - 2, size - 2),
        fill=(255, 255, 255, 255),
        outline=(0, 0, 0, 255),
        width=2 * scale,
    )

    img = img.resize((thumb_radius * 2, thumb_radius * 2), Image.LANCZOS)
    thumb_img = ImageTk.PhotoImage(img)
    val_canvas.thumb_img = thumb_img

    val_thumb = val_canvas.create_image(
        int(x),
        HUE_SLIDER_HEIGHT // 2,
        image=thumb_img
    )

def on_rgb_canvas_event(canvas, channel, event):
    global current_rgb, updating_color_ui, hsv_authoritative
    clear_preset_selection()
    if updating_color_ui:
        return

    width = canvas.winfo_width()
    if width <= 1:
        return

    x = min(max(event.x, 0), width - 1)
    value = int((x / (width - 1)) * 255)

    r, g, b = current_rgb
    if channel == "r":
        r = value
    elif channel == "g":
        g = value
    else:
        b = value

    current_rgb = (r, g, b)

    hsv_authoritative = False

    updating_color_ui = True
    sync_all_color_controls()
    updating_color_ui = False

def on_hue_slider_event(event):
    global current_h, current_rgb, updating_color_ui

    if updating_color_ui:
        return

    width = hue_canvas.winfo_width()
    if width <= 1:
        return

    x = min(max(event.x, 0), width - 1)
    current_h = x / (width - 1)

    r, g, b = colorsys.hsv_to_rgb(current_h, current_s, current_v)
    current_rgb = (int(r * 255), int(g * 255), int(b * 255))

    updating_color_ui = True
    sync_all_color_controls()
    updating_color_ui = False

def on_sat_slider_event(event):
    global current_s, current_rgb, updating_color_ui, hsv_authoritative

    if updating_color_ui:
        return

    hsv_authoritative = True

    width = sat_canvas.winfo_width()
    if width <= 1:
        return

    x = sat_canvas.canvasx(event.x)
    x = min(max(x, 0), width - 1)

    current_s = x / (width - 1)

    r, g, b = colorsys.hsv_to_rgb(current_h, current_s, current_v)
    current_rgb = (int(r * 255), int(g * 255), int(b * 255))

    updating_color_ui = True
    sync_all_color_controls()
    updating_color_ui = False

def on_val_slider_event(event):
    global current_v, current_rgb, updating_color_ui, hsv_authoritative

    if updating_color_ui:
        return

    hsv_authoritative = True

    width = val_canvas.winfo_width()
    if width <= 1:
        return

    x = val_canvas.canvasx(event.x)
    x = min(max(x, 0), width - 1)

    current_v = x / (width - 1)

    r, g, b = colorsys.hsv_to_rgb(current_h, current_s, current_v)
    current_rgb = (int(r * 255), int(g * 255), int(b * 255))

    updating_color_ui = True
    sync_all_color_controls()
    updating_color_ui = False

def wheel_xy_to_hs(x, y):
    cx = cy = wheel_size // 2
    dx = x - cx
    dy = y - cy

    dist = math.sqrt(dx*dx + dy*dy)
    if dist > cx:
        return None

    angle = math.atan2(dy, dx)

    hue = (angle + math.pi) / (2 * math.pi)# If I see one more "tan" or one more "pi" im gonna lose it
    sat = min(1.0, dist / cx)
    return hue, sat

def draw_wheel_marker(h, s):
    global wheel_marker

    cx = cy = wheel_size // 2
    r = s * cx

    angle = h * 2 * math.pi - math.pi
    x = cx + math.cos(angle) * r
    y = cy + math.sin(angle) * r

    if wheel_marker:
        wheel_canvas.delete(wheel_marker)

    scale = 2
    radius = 6 * scale
    size = radius * 2 + 2

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse(
        (1, 1, size - 2, size - 2),
        fill=(255, 255, 255, 255),
        outline=(0, 0, 0, 255),
        width=2 * scale,
    )

    img = img.resize(
        (radius, radius),
        Image.LANCZOS
    )

    marker_img = ImageTk.PhotoImage(img)
    wheel_canvas.marker_img = marker_img

    wheel_marker = wheel_canvas.create_image(
        x,
        y,
        image=marker_img
    )

def update_from_wheel(x, y):
    global current_rgb, current_h, current_s, updating_color_ui

    hs = wheel_xy_to_hs(x, y)
    if hs is None:
        return

    current_h, current_s = hs

    r, g, b = colorsys.hsv_to_rgb(current_h, current_s, current_v)
    current_rgb = (int(r * 255), int(g * 255), int(b * 255))

    updating_color_ui = True
    sync_all_color_controls()
    updating_color_ui = False

    draw_wheel_marker(current_h, current_s)

def on_rgb_slider(channel, value):
    global current_rgb

    if wheel_drag_active or updating_color_ui:
        return

    r, g, b = current_rgb
    v = int(value)

    if channel == "r": r = v
    elif channel == "g": g = v
    elif channel == "b": b = v

    current_rgb = (r, g, b)
    sync_all_color_controls()

def on_hsv_slider(channel, value):
    global current_h, current_s, current_v, current_rgb

    if wheel_drag_active or updating_color_ui:
        return

    if channel == "h":
        current_h = value / 360.0
    elif channel == "s":
        current_s = value / 100.0
    elif channel == "l":
        current_v = value / 100.0

    r, g, b = colorsys.hsv_to_rgb(current_h, current_s, current_v)
    current_rgb = (int(r * 255), int(g * 255), int(b * 255))

    sync_all_color_controls()

def on_rgb_entry(entry_var, channel):
    global updating_color_ui, current_rgb

    if updating_color_ui:
        return

    try:
        v = int(entry_var.get())
    except ValueError:
        return

    v = max(0, min(255, v))

    hsv_authoritative = False
    updating_color_ui = True

    r, g, b = current_rgb
    if channel == "r":
        r = v
    elif channel == "g":
        g = v
    elif channel == "b":
        b = v

    current_rgb = (r, g, b)

    sync_all_color_controls()

    updating_color_ui = False

def on_hex_entry(event=None):
    global current_rgb, user_editing_color

    if updating_color_ui:
        return

    text = hex_var.get().strip()
    if not (text.startswith("#") and len(text) == 7):
        return

    try:
        r = int(text[1:3], 16)
        g = int(text[3:5], 16)
        b = int(text[5:7], 16)
    except ValueError:
        return

    user_editing_color = True
    current_rgb = (r, g, b)
    sync_all_color_controls()
    user_editing_color = False

def on_hex_change(*args):
    global hex_update_job

    if wheel_drag_active or updating_color_ui:
        return

    if hex_update_job is not None:
        root.after_cancel(hex_update_job)

    hex_update_job = root.after(250, apply_hex_if_valid)

def apply_hex_if_valid():
    global current_rgb, user_editing_color, updating_color_ui

    text = hex_var.get().strip()

    if not text.startswith("#"):
        text = "#" + text

    if len(text) != 7:
        return

    try:
        r = int(text[1:3], 16)
        g = int(text[3:5], 16)
        b = int(text[5:7], 16)
    except ValueError:
        return

    user_editing_color = True
    updating_color_ui = True

    current_rgb = (r, g, b)

    sync_all_color_controls()

    updating_color_ui = False
    user_editing_color = False

def sync_all_color_controls():
    if current_mode != "rgb":
        return
    global updating_color_ui, current_h, current_s, current_v
    
    updating_color_ui = True

    r, g, b = current_rgb

    r_canvas.delete("all")
    grad = generate_rgb_gradient(
        r_canvas.winfo_width(),
        HUE_SLIDER_HEIGHT,
        "r",
        r, g, b
    )
    r_canvas.gradient_img = grad
    r_canvas.create_image(0, 0, anchor="nw", image=grad)
    draw_rgb_thumb(r_canvas, r)

    g_canvas.delete("all")
    grad = generate_rgb_gradient(
        g_canvas.winfo_width(),
        HUE_SLIDER_HEIGHT,
        "g",
        r, g, b
    )
    g_canvas.gradient_img = grad
    g_canvas.create_image(0, 0, anchor="nw", image=grad)
    draw_rgb_thumb(g_canvas, g)

    b_canvas.delete("all")
    grad = generate_rgb_gradient(
        b_canvas.winfo_width(),
        HUE_SLIDER_HEIGHT,
        "b",
        r, g, b
    )
    b_canvas.gradient_img = grad
    b_canvas.create_image(0, 0, anchor="nw", image=grad)
    draw_rgb_thumb(b_canvas, b)

    r_var.set(str(r))
    g_var.set(str(g))
    b_var.set(str(b))
    # ---- HEX ----
    hex_var.set(f"#{r:02X}{g:02X}{b:02X}")
    # ---- HSV ----
    if not hsv_authoritative:
        h, s, v = colorsys.rgb_to_hsv(
            current_rgb[0] / 255,
            current_rgb[1] / 255,
            current_rgb[2] / 255,
        )
        current_h, current_s, current_v = h, s, v

    h_deg = int(current_h * 360)
    s_pct = int(current_s * 100)
    v_pct = int(current_v * 100)

    h_var.set(str(int(current_h * 360)))
    draw_hue_thumb(current_h)

    s_var.set(str(s_pct))

    sat_canvas.delete("all")
    gradient = generate_saturation_gradient(
        sat_canvas.winfo_width(),
        HUE_SLIDER_HEIGHT,
        current_h,
        current_v
    )
    sat_canvas.gradient_img = gradient
    sat_canvas.create_image(0, 0, anchor="nw", image=gradient)
    draw_sat_thumb(current_s)
    v_pct = int(current_v * 100)
    v_var.set(str(v_pct))
    val_canvas.delete("all")
    gradient = generate_value_gradient(
        val_canvas.winfo_width(),
        HUE_SLIDER_HEIGHT,
        current_h,
        current_s
    )
    val_canvas.gradient_img = gradient
    val_canvas.create_image(0, 0, anchor="nw", image=gradient)
    draw_val_thumb(current_v)

    h_var.set(str(h_deg))
    s_var.set(str(s_pct))
    v_var.set(str(v_pct))

    draw_wheel_marker(current_h, current_s)
    update_color_preview()
    updating_color_ui = False
    redraw_brightness_slider()

def make_slider(parent, label, min_val, max_val, command):
    frame = ctk.CTkFrame(
        parent,
        fg_color=SLIDER_BG_COLOR,
        corner_radius=8
    )
    frame.pack(fill="x", pady=4)

    label_widget = ctk.CTkLabel(frame, text=label, width=36)
    label_widget.pack(side="left", padx=(8, 4))

    var = ctk.StringVar(value=str(min_val))

    slider = ctk.CTkSlider(
        frame,
        from_=min_val,
        to=max_val,
        command=command,
        height=16,

        fg_color="transparent",
        progress_color="transparent",
        button_color="transparent",
        button_hover_color="transparent",
    )
    slider.pack(side="left", padx=6, fill="x", expand=True)

    entry = ctk.CTkEntry(
        frame,
        textvariable=var,
        width=56,
        justify="center"
    )
    entry.pack(side="right", padx=(4, 8))

    return slider, var, entry

def on_hsv_entry(entry_var, channel):
    global updating_color_ui, current_rgb
    global current_h, current_s, current_v, hsv_authoritative

    if updating_color_ui:
        return

    try:
        value = float(entry_var.get())
    except ValueError:
        return

    hsv_authoritative = True
    updating_color_ui = True

    if channel == "h":
        current_h = max(0.0, min(360.0, value)) / 360.0
    elif channel == "s":
        current_s = max(0.0, min(100.0, value)) / 100.0
    elif channel == "l":
        current_v = max(0.0, min(100.0, value)) / 100.0

    r, g, b = colorsys.hsv_to_rgb(current_h, current_s, current_v)
    current_rgb = (int(r * 255), int(g * 255), int(b * 255))

    sync_all_color_controls()
    updating_color_ui = False

commit_rgb_entry = debounce(on_rgb_entry, 300)
commit_hsv_entry = debounce(on_hsv_entry, 300)

def redraw_hue_gradient(event=None):
    hue_canvas.delete("all")

    width = hue_canvas.winfo_width()
    if width <= 1:
        return

    gradient = generate_hue_gradient(width, HUE_SLIDER_HEIGHT)

    hue_canvas.gradient_img = gradient

    hue_canvas.create_image(
        0, 0,
        anchor="nw",
        image=gradient
    )

    draw_hue_thumb(current_h)

def apply_color_from_controls():
    global current_rgb, device_rgb, selected_preset_name

    selected_preset_name = None

    r = int(r_var.get())
    g = int(g_var.get())
    b = int(b_var.get())

    current_rgb = (r, g, b)

    device_rgb = current_rgb
    save_last_rgb(device_rgb)
    update_brightness_source_from_device()

    sync_all_color_controls()
    redraw_brightness_slider()
    update_light()
    rebuild_preset_buttons()

def apply_color_from_picker():
    global current_rgb, selected_preset_name

    if not hex_color:
        return

    selected_preset_name = None

    try:
        r = int(hex_color[1:3], 16)
        g = int(hex_color[3:5], 16)
        b = int(hex_color[5:7], 16)
    except ValueError:
        return

    current_rgb = (r, g, b)

    update_light()
    rebuild_preset_buttons()

def open_discovery_dialog():
    saved_lights = load_saved_lights()

    dialog = ctk.CTkToplevel(root)
    dialog.title("Discover WiZ Lights")
    apply_window_icon(dialog)
    dialog.resizable(False, False)
    center_window(dialog, root, 460, 429)
    dialog.transient(root)

    ctk.CTkLabel(dialog, text="Discovered Lights", font=ctk.CTkFont(weight="bold")).pack(pady=(10, 4))

    discovered = tk.Listbox(
        dialog,
        height=7,
        bg="#2b2b2b",
        fg="white",
        selectbackground=accent_color,
        highlightthickness=0,
    )
    discovered.pack(fill="x", padx=14)

    discovered_map = {}

    ctk.CTkLabel(dialog, text="Saved Lights", font=ctk.CTkFont(weight="bold")).pack(pady=(12, 4))

    saved_listbox = tk.Listbox(
        dialog,
        height=7,
        bg="#2b2b2b",
        fg="white",
        selectbackground=highlight_color,
        highlightthickness=0,
    )
    saved_listbox.pack(fill="x", padx=14)


    def _rebuild_saved():
        saved_listbox.delete(0, tk.END)
        for mac, d in saved_lights.items():
            saved_listbox.insert(tk.END, f"{d['name']} — {d['ip']}  [{format_mac(mac)}]")

    _rebuild_saved()

    status = ctk.CTkLabel(dialog, text="Scanning network…")
    status.pack(pady=6)

    def _on_found(name, ip, mac):
        if mac in saved_lights:
            if saved_lights[mac]["ip"] != ip:
                saved_lights[mac]["ip"] = ip
                save_saved_lights(saved_lights)
                _rebuild_saved()
            return

        for d in discovered_map.values():
            if d["mac"] == mac:
                return

        idx = discovered.size()
        discovered_map[idx] = {"mac": mac, "ip": ip, "name": name}
        discovered.insert(tk.END, f"{name} — {ip}  [{format_mac(mac)}]")

    def _on_done(found):
        try:
            if not dialog.winfo_exists():
                return

            if discovered.size() > 0:
                status.configure(text="Scan complete.")
            elif saved_listbox.size() > 0:
                status.configure(text="Scan complete — saved lights discovered.")
            else:
                status.configure(text="No WiZ lights found.")
        except tk.TclError:
            pass

    def _start_scan():
        discovered.delete(0, tk.END)
        discovered_map.clear()
        status.configure(text="Scanning network…")
        discover_stop_flag.clear()

        discover_wiz_lights(
            on_found=_on_found,
            on_done=_on_done,
        )

    def _apply_ip(ip):
        discover_stop_flag.set()
        ip_var.set(ip)
        save_last_ip(ip)
        dialog.destroy()
        root.after(100, sync_from_light)

    def _dbl_discovered(event):
        sel = discovered.curselection()
        if sel:
            _apply_ip(discovered_map[sel[0]]["ip"])

    def _dbl_saved(event):
        sel = saved_listbox.curselection()
        if sel:
            mac = list(saved_lights.keys())[sel[0]]
            _apply_ip(saved_lights[mac]["ip"])

    discovered.bind("<Double-Button-1>", _dbl_discovered)
    saved_listbox.bind("<Double-Button-1>", _dbl_saved)

    menu = tk.Menu(dialog, tearoff=0)

    def _right_discovered(event):
        idx = discovered.nearest(event.y)
        if idx not in discovered_map:
            return

        def _save():
            d = discovered_map[idx]
            open_name_light_dialog(d["mac"], d["ip"], d["name"], saved_lights, _rebuild_saved)

        menu.delete(0, tk.END)
        menu.add_command(label="Save Light", command=_save)
        menu.tk_popup(event.x_root, event.y_root)

    def _right_saved(event):
        idx = saved_listbox.nearest(event.y)
        if idx >= len(saved_lights):
            return

        mac = list(saved_lights.keys())[idx]

        def _rename():
            open_rename_light_dialog(mac, saved_lights, _rebuild_saved)

        def _delete():
            saved_lights.pop(mac)
            save_saved_lights(saved_lights)
            _rebuild_saved()

        menu.delete(0, tk.END)
        menu.add_command(label="Rename", command=_rename)
        menu.add_command(label="Delete", command=_delete)
        menu.tk_popup(event.x_root, event.y_root)

    discovered.bind("<Button-3>", _right_discovered)
    saved_listbox.bind("<Button-3>", _right_saved)

    ctk.CTkButton(
        dialog,
        text="Rescan",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=_start_scan,
    ).pack(pady=12)

    dialog.after(50, _start_scan)

def open_ip_help_dialog():
    dialog = ctk.CTkToplevel(root)
    dialog.title("Help & Guide")
    apply_window_icon(dialog)
    center_window(dialog, root, 540, 580)

    dialog.transient(root)
    dialog.lift()
    dialog.attributes("-topmost", True)
    dialog.after(200, lambda: dialog.attributes("-topmost", False))

    container = ctk.CTkFrame(dialog, fg_color="transparent")
    container.pack(fill="both", expand=True, padx=18, pady=18)

    ctk.CTkLabel(
        container,
        text="WiZ Light Controller – Help Guide",
        font=ctk.CTkFont(size=17, weight="bold"),
    ).pack(anchor="w", pady=(0, 12))

    scroll = ctk.CTkScrollableFrame(container)
    scroll.pack(fill="both", expand=True)

    def section(title, body):
        ctk.CTkLabel(
            scroll,
            text=title,
            font=ctk.CTkFont(size=14, weight="bold"),
            anchor="w",
        ).pack(fill="x", pady=(14, 4))

        ctk.CTkLabel(
            scroll,
            text=body,
            justify="left",
            wraplength=480,
            anchor="w",
        ).pack(fill="x")

    section(
        "First-time setup",
        "• Make sure your computer and the WiZ light are on the SAME Wi-Fi network.\n"
        " (You DO need the WiZ app on your Android or Apple device to make a new WiZ light connect to your network.)\n"
        "• Make sure the light is ON using the mains switch.\n"
        "• You do NOT need the official WiZ app on your phone running to use this app, just for first time setup.",
    )

    section(
        "Finding your light automatically (Recommended)",
        "• Click the Wi-Fi / discovery icon next to the IP box.\n"
        "• The app scans your local network for WiZ lights.\n"
        "• Double-click a discovered light to connect instantly.\n"
        "• Lights can be saved so they always appear, even if their IP changes.",
    )

    section(
        "Manual IP entry",
        "If discovery fails to work:\n"
        "• Make sure the app is not being blocked by a firewall or a VPN. If it still doesn't work:\n"
        "• Open your router’s admin page (commonly 192.168.1.1 or 192.168.0.1).\n"
        "• Go to Connected Devices / DHCP Clients.\n"
        "• Look for a device named something like:\n"
        "  ESP25_XXXXXX / wiz_XXXXXX\n"
        "• Copy its IP address into the WiZ IP box.\n"
        "• Press “Sync from Light”.",
    )

    section(
        "Saved lights",
        "• Right-click a discovered light → Save.\n"
        "• If a light’s IP changes, it updates automatically.\n"
        "• You can rename or delete saved lights via a right-click.\n"
        "• Double-click a saved light to connect to it instantly.",
    )

    section(
        "Presets",
        "• Presets store the FULL state of the light:\n"
        "  color / temperature / brightness / mode.\n\n"
        "• Clicking a preset immediately applies it to the light.\n"
        "• The active preset is highlighted automatically.\n"
        "• If you manually change sliders so the state no longer matches,\n"
        "  the preset highlight will turn off.",
    )

    section(
        "Editing presets",
        "• Click “Save Preset”, then choose which preset slot to overwrite.\n"
        "• Presets are mode-specific:\n"
        "  RGB presets do NOT appear in White mode, and vice-versa.\n\n"
        "Right-click a preset to:\n"
        "• Rename it\n"
        "• Reorder it (Move Left / Right)\n"
        "• View its stored values\n\n"
        "Preset values are saved automatically and persist across restarts.",
    )

    section(
        "Syncing & control",
        "• “Sync from Light” reads the ACTUAL state of the bulb.\n"
        "• Use it if the UI and the light feel out of sync.\n"
        "• Auto-Sync can be enabled or disabled in Settings.\n"
        "• Sync does NOT overwrite presets unless you save explicitly.",
    )

    section(
        "Common issues (Important)",
        "• WiZ lights sometimes ignore commands briefly.\n"
        " (This is unavoidable behavior, due to the lights going into a kind of 'sleep' mode to save on power)\n"
        "• If a command doesn’t apply, wait a moment and try again.\n"
        "• Discovery may occasionally miss a light — rescanning usually fixes it.\n"
        "• Firewalls, VPNs, or guest networks can break discovery.",
    )

    section(
        "Good to know",
        "• Your last used IP and color values are saved automatically.\n"
        "• Presets always reflect the bulb’s REAL state, not just UI sliders.\n"
        "• The app never sends commands faster than the built-in safety debounce, which is 250 ms.",
    )

    ctk.CTkButton(
        container,
        text="Close",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=dialog.destroy,
    ).pack(pady=(16, 0))

def open_name_light_dialog(mac, ip, default_name, saved_lights, refresh):
    dialog = ctk.CTkToplevel(root)
    dialog.title("Save Light")
    apply_window_icon(dialog)
    center_window(dialog, root, 300, 160)
    dialog.grab_set()

    ctk.CTkLabel(dialog, text="Name this light:").pack(pady=(14, 4))
    entry = ctk.CTkEntry(dialog, width=220)
    entry.insert(0, default_name)
    entry.pack(pady=6)
    entry.focus()

    def save():
        name = entry.get().strip()
        if not name:
            return
        saved_lights[mac] = {"name": name, "ip": ip}
        save_saved_lights(saved_lights)
        refresh()
        dialog.destroy()

    ctk.CTkButton(
        dialog,
        text="Save",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=save,
    ).pack(pady=10)

def open_rename_light_dialog(mac, saved_lights, refresh):
    dialog = ctk.CTkToplevel(root)
    dialog.title("Rename Light")
    apply_window_icon(dialog)
    center_window(dialog, root, 300, 160)
    dialog.grab_set()

    entry = ctk.CTkEntry(dialog, width=220)
    entry.insert(0, saved_lights[mac]["name"])
    entry.pack(pady=20)
    entry.focus()

    def rename():
        name = entry.get().strip()
        if name:
            saved_lights[mac]["name"] = name
            save_saved_lights(saved_lights)
            refresh()
        dialog.destroy()

    ctk.CTkButton(
        dialog,
        text="Rename",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=rename,
    ).pack(pady=10)

def apply_theme_colors():
    g = globals()

    for name in ("sync_button", "save_preset_button", "apply_color_btn"):
        widget = g.get(name)
        if widget:
            try:
                widget.configure(
                    fg_color=accent_color,
                    hover_color=hex_add_24(accent_color),
                )
            except Exception:
                pass

    power = g.get("power_segment")
    if power:
        try:
            power.configure(
                selected_color=accent_color,
                selected_hover_color=hex_add_24(accent_color),
            )
        except Exception:
            pass

    mode = g.get("mode_segment")
    if mode:
        try:
            mode.configure(
                selected_color=accent_color,
                selected_hover_color=hex_add_24(accent_color),
            )
        except Exception:
            pass

    if "rebuild_preset_buttons" in g:
        try:
            rebuild_preset_buttons()
        except Exception:
            pass

def open_settings_dialog():
    global accent_color, highlight_color

    dialog = ctk.CTkToplevel(root)
    dialog.title("Settings")
    apply_window_icon(dialog)
    dialog.resizable(False, True)
    center_window(dialog, root, 420, 328)

    dialog.grab_set()
    dialog.transient(root)

    content = ctk.CTkFrame(dialog, fg_color="transparent")
    content.pack(padx=20, pady=20, fill="both", expand=True)

    ctk.CTkLabel(
        content,
        text="Appearance & Behavior",
        font=ctk.CTkFont(size=15, weight="bold"),
    ).pack(anchor="w", pady=(0, 10))

    ctk.CTkLabel(content, text="Accent Color").pack(anchor="w")

    accent_row = ctk.CTkFrame(content, fg_color="transparent")
    accent_row.pack(anchor="w", pady=(0, 10))

    accent_var = tk.StringVar(value=accent_color)
    accent_entry = ctk.CTkEntry(accent_row, textvariable=accent_var, width=140)
    accent_entry.pack(side="left")

    accent_preview = ctk.CTkFrame(
        accent_row,
        width=22,
        height=22,
        corner_radius=4,
        fg_color=accent_color,
    )
    accent_preview.pack(side="left", padx=(8, 0))
    accent_error = ctk.CTkLabel(
        content,
        text="Invalid Hexcode",
        text_color="#ff5c5c",
    )
    accent_error.pack(anchor="w", pady=(0, 6))
    accent_error.pack_forget()

    def on_accent_hex_change(event=None):
        update_hex_preview(
            accent_var,
            accent_preview,
            DEFAULT_ACCENT,
        )

    accent_entry.bind("<KeyRelease>", on_accent_hex_change)

    ctk.CTkLabel(content, text="Highlighted Preset Color").pack(anchor="w")

    highlight_row = ctk.CTkFrame(content, fg_color="transparent")
    highlight_row.pack(anchor="w")

    highlight_var = tk.StringVar(value=highlight_color)
    highlight_entry = ctk.CTkEntry(highlight_row, textvariable=highlight_var, width=140)
    highlight_entry.pack(side="left")

    highlight_preview = ctk.CTkFrame(
        highlight_row,
        width=22,
        height=22,
        corner_radius=4,
        fg_color=highlight_color,
    )
    highlight_preview.pack(side="left", padx=(8, 0))
    highlight_error = ctk.CTkLabel(
        content,
        text="Invalid Hexcode.",
        text_color="#ff5c5c",
    )
    highlight_error.pack(anchor="w")
    highlight_error.pack_forget()

    def on_highlight_hex_change(event=None):
        update_hex_preview(
            highlight_var,
            highlight_preview,
            DEFAULT_HIGHLIGHT,
        )

    highlight_entry.bind("<KeyRelease>", on_highlight_hex_change)

    ctk.CTkLabel(
        content,
        text="Auto-Sync on Startup",
    ).pack(anchor="w", pady=(10, 2))

    auto_sync_var = tk.BooleanVar(value=auto_sync_enabled)

    auto_sync_switch = ctk.CTkSwitch(
        content,
        text="Automatically sync from light when app starts",
        
        variable=auto_sync_var,
        onvalue=True,
        offvalue=False,
        progress_color=accent_color,
    )
    auto_sync_switch.pack(anchor="w", pady=(0, 10))

    btn_row = ctk.CTkFrame(dialog, fg_color="transparent")
    btn_row.pack(pady=(10, 16), fill="x")

    def reset_defaults():
        nonlocal accent_var, highlight_var
        accent_var.set(DEFAULT_ACCENT)
        highlight_var.set(DEFAULT_HIGHLIGHT)
        auto_sync_var.set(True)

    def save_and_close():
        global accent_color, highlight_color, auto_sync_enabled
        accent_ok = is_valid_hex_color(accent_var.get())
        highlight_ok = is_valid_hex_color(highlight_var.get())

        if not accent_ok:
            accent_error.pack(anchor="w", pady=(0, 6))
        if not highlight_ok:
            highlight_error.pack(anchor="w")

        if not accent_ok or not highlight_ok:
            return

        accent_color = sanitize_hex_color(
            accent_var.get(),
            DEFAULT_ACCENT,
        )
        highlight_color = sanitize_hex_color(
            highlight_var.get(),
            DEFAULT_HIGHLIGHT,
        )
        auto_sync_enabled = bool(auto_sync_var.get())
        
        save_settings()
        apply_theme_colors()
        dialog.destroy()

    ctk.CTkButton(
        btn_row,
        text="Reset Defaults",
        width=120,
        fg_color="#444444",
        hover_color="#555555",
        command=reset_defaults,
    ).pack(side="left", padx=12)

    ctk.CTkButton(
        btn_row,
        text="Save and Close",
        width=130,
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=save_and_close,
    ).pack(side="right", padx=12)
    
    ctk.CTkButton(
        btn_row,
        text="Close",
        width=90,
        fg_color="#444444",
        hover_color="#555555",
        command=dialog.destroy,
    ).pack(side="right", padx=0)

def on_slider_release(event=None):
    rebuild_preset_buttons()

def preset_matches_current_state(preset):
    if preset["mode"] != current_mode:
        return False

    if preset.get("brightness", 100) != current_brightness:
        return False

    if preset["mode"] == "rgb":
        return (
            preset["r"] == device_rgb[0]
            and preset["g"] == device_rgb[1]
            and preset["b"] == device_rgb[2]
        )

    return preset["temp"] == device_temp

def make_color_box(parent, r, g, b, size=24):
    color = f"#{r:02x}{g:02x}{b:02x}"
    box = ctk.CTkFrame(
        parent,
        width=size,
        height=size,
        fg_color=color,
        corner_radius=6,
    )
    box.pack_propagate(False)
    return box

def center_window(window, parent, width, height):
    parent.update_idletasks()

    px = parent.winfo_x()
    py = parent.winfo_y()
    pw = parent.winfo_width()
    ph = parent.winfo_height()

    x = px + (pw // 2) - (width // 2)
    y = py + (ph // 2) - (height // 2)

    window.geometry(f"{width}x{height}+{x}+{y}")

def update_light():
    global current_state, current_rgb, current_brightness, current_temp, current_mode

    if is_syncing:
        return

    params = {"state": bool(current_state)}

    if not current_state:
        schedule_send(params)
        return

    params["dimming"] = int(current_brightness)

    if current_mode == "rgb":
        global device_rgb
        r, g, b = current_rgb
        device_rgb = (r, g, b)
        params.update({
            "r": int(r),
            "g": int(g),
            "b": int(b),
        })
    else:
        global device_temp
        device_temp = current_temp
        params.update({
            "temp": int(current_temp),
        })


    schedule_send(params)

def turn_on():
    global current_state
    if not connected:
        messagebox.showinfo("Not connected", "Press 'Sync from Light' first to connect.")
        return
    current_state = True
    state_label.configure(text="State: ON")
    schedule_send({"state": True})

def turn_off():
    global current_state
    if not connected:
        messagebox.showinfo("Not connected", "Press 'Sync from Light' first to connect.")
        return
    current_state = False
    state_label.configure(text="State: OFF")
    schedule_send({"state": False})

def on_brightness_change(value):
    global current_brightness, selected_preset_name

    selected_preset_name = None
    current_brightness = int(float(value))

    brightness_varue_label.configure(text=f"{current_brightness}%")

    update_brightness_source_from_device()
    redraw_brightness_slider()

    if is_syncing:
        return

    update_light()

def set_mode_rgb():
    global current_mode, selected_preset_name
    global current_rgb, current_h, current_s, current_v
    global hsv_authoritative, device_rgb

    current_mode = "rgb"
    selected_preset_name = None

    device_rgb = load_last_rgb()
    current_rgb = device_rgb

    current_h, current_s, current_v = colorsys.rgb_to_hsv(
        current_rgb[0] / 255,
        current_rgb[1] / 255,
        current_rgb[2] / 255,
    )

    hsv_authoritative = False

    sync_all_color_controls()
    redraw_brightness_slider()

    update_control_states()
    rebuild_preset_buttons()

def set_mode_white():
    global current_mode, selected_preset_name
    global current_temp

    current_mode = "white"
    selected_preset_name = None

    current_temp = device_temp

    sync_all_color_controls()
    redraw_brightness_slider()

    update_control_states()
    rebuild_preset_buttons()

def open_rename_preset_dialog(mode, old_name):
    dialog = ctk.CTkToplevel(root)
    dialog.title("Rename Preset")
    apply_window_icon(dialog)
    center_window(dialog, root, 300, 150)
    dialog.grab_set()

    ctk.CTkLabel(
        dialog,
        text=f"Rename '{old_name}' to:"
    ).pack(pady=(15, 5))

    entry = ctk.CTkEntry(dialog, width=220)
    entry.insert(0, old_name)
    entry.pack(pady=5)
    entry.focus()

    def confirm():
        new_name = entry.get().strip()
        if not new_name or new_name == old_name:
            dialog.destroy()
            return

        if new_name in presets[mode]:
            messagebox.showerror("Error", "Preset name already exists.")
            return

        presets[mode][new_name] = presets[mode].pop(old_name)

        global selected_preset_name
        if selected_preset_name == old_name:
            selected_preset_name = new_name

        save_presets()
        rebuild_preset_buttons()
        dialog.destroy()

    ctk.CTkButton(
        dialog,
        text="Rename",
        command=confirm,
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
    ).pack(pady=10)

def open_preset_actions_dialog(mode, preset_name):
    preset = presets[mode][preset_name]

    dialog = ctk.CTkToplevel(root)
    dialog.title(preset_name)
    apply_window_icon(dialog)
    center_window(dialog, root, 300, 300)
    dialog.grab_set()

    ctk.CTkLabel(
        dialog,
        text=preset_name,
        font=ctk.CTkFont(size=15, weight="bold"),
    ).pack(pady=(12, 6))

    info_frame = ctk.CTkFrame(dialog)
    info_frame.pack(padx=15, pady=(0, 10), fill="x")

    if preset["mode"] == "rgb":
        r, g, b = preset["r"], preset["g"], preset["b"]

        row = ctk.CTkFrame(info_frame)
        row.pack(pady=6)

        make_color_box(row, r, g, b).pack(side="left", padx=(0, 8))

        ctk.CTkLabel(
            row,
            text=f"RGB({r}, {g}, {b})",
        ).pack(side="left")

        ctk.CTkLabel(
            info_frame,
            text=f"Brightness: {preset.get('brightness', 100)}%",
        ).pack(pady=(0, 4))

    else:
        ctk.CTkLabel(
            info_frame,
            text=f"Temperature: {preset['temp']} K",
        ).pack(pady=(6, 2))

        ctk.CTkLabel(
            info_frame,
            text=f"Brightness: {preset.get('brightness', 100)}%",
        ).pack(pady=(0, 4))

    ctk.CTkButton(
        dialog,
        text="Rename",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=lambda: (
            dialog.destroy(),
            open_rename_preset_dialog(mode, preset_name),
        ),
    ).pack(pady=4)

    ctk.CTkButton(
        dialog,
        text="Move Left",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=lambda: (
            dialog.destroy(),
            move_preset(mode, preset_name, -1),
        ),
    ).pack(pady=4)

    ctk.CTkButton(
        dialog,
        text="Move Right",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=lambda: (
            dialog.destroy(),
            move_preset(mode, preset_name, +1),
        ),
    ).pack(pady=4)

    ctk.CTkButton(
        dialog,
        text="Close",
        fg_color="#444444",
        hover_color="#555555",
        command=dialog.destroy,
    ).pack(pady=(8, 12))

def move_preset(mode, name, direction):
    keys = list(presets[mode].keys())
    if name not in keys:
        return

    idx = keys.index(name)
    new_idx = idx + direction

    if new_idx < 0 or new_idx >= len(keys):
        return

    keys[idx], keys[new_idx] = keys[new_idx], keys[idx]

    presets[mode] = {k: presets[mode][k] for k in keys}

    save_presets()
    rebuild_preset_buttons()

def apply_preset_by_name(name: str):
    global current_mode, current_rgb, current_temp
    global current_brightness, device_rgb, device_temp
    global selected_preset_name

    p = presets[current_mode][name]
    selected_preset_name = name

    target_brightness = p.get("brightness", current_brightness)

    if p["mode"] == "rgb":
        current_mode = "rgb"
        mode_segment.set("RGB")

        current_rgb = (p["r"], p["g"], p["b"])
        device_rgb = current_rgb

    else:
        current_mode = "white"
        mode_segment.set("White")

        old_temp = current_temp
        current_temp = int(p["temp"])
        device_temp = current_temp

        temp_varue_label.configure(text=f"{current_temp}K")
        redraw_temp_slider()

        animate_label_change(
            temp_varue_label,
            old_temp,
            current_temp,
            suffix="K",
        )

    old_brightness = current_brightness
    current_brightness = target_brightness

    update_brightness_source_from_device()
    redraw_brightness_slider()
    animate_brightness_to(target_brightness)

    if current_mode == "white":
        temp_varue_label.configure(text=f"{current_temp}K")
        redraw_temp_slider()

    sync_all_color_controls()
    update_light()
    update_control_states()
    rebuild_preset_buttons()

def apply_preset_rgb(r, g, b, brightness=None):
    global current_mode, current_rgb, current_brightness
    if current_mode != "rgb":
        return

    old_brightness = current_brightness
    current_rgb = (r, g, b)

    if brightness is not None:
        current_brightness = brightness
        animate_brightness_to(current_brightness)
        try:
            animate_label_change(
                brightness_varue_label,
                old_brightness,
                current_brightness,
                suffix="%",
            )
        except NameError:
            brightness_varue_label.configure(text=f"{current_brightness}%")

    update_light()

def apply_preset_white(temp, brightness=None):
    global current_mode, current_temp, current_brightness
    if current_mode != "white":
        return

    old_temp = current_temp
    old_brightness = current_brightness

    current_temp = temp
    try:
        animate_label_change(
            temp_varue_label,
            old_temp,
            current_temp,
            suffix="K",
            slider=temp_slider,
        )
    except NameError:

        temp_varue_label.configure(text=f"{current_temp}K")

    if brightness is not None:
        current_brightness = brightness
        try:
            animate_label_change(
                brightness_varue_label,
                old_brightness,
                current_brightness,
                suffix="%",
                slider=brightness_slider,
            )
        except NameError:
            animate_brightness_to(current_brightness)
            brightness_varue_label.configure(text=f"{current_brightness}%")

    update_light()

# ===== RGB MODE PRESETS =====
def preset_red():
    apply_preset_rgb(255, 0, 0, brightness=None)

def preset_green():
    apply_preset_rgb(0, 255, 0, brightness=None)

def preset_blue():
    apply_preset_rgb(0, 0, 255, brightness=None)

def preset_accent_color():
    apply_preset_rgb(128, 0, 255, brightness=None)

def preset_sunset():
    apply_preset_rgb(255, 120, 40, brightness=None)

def preset_ocean():
    apply_preset_rgb(0, 130, 255, brightness=None)

def preset_aqua():
    apply_preset_rgb(0, 255, 255, brightness=None)

# ===== WHITE MODE PRESETS =====
def preset_full_white():
    apply_preset_white(6500, brightness=100)

def preset_warmish():
    apply_preset_white(4000, brightness=100)

def preset_relax():
    apply_preset_white(3000, brightness=100)

def preset_full_warm():
    apply_preset_white(2200, brightness=100)

def preset_dim_relax():
    apply_preset_white(2700, brightness=25)

def preset_dim_white():
    apply_preset_white(6500, brightness=35)

def open_sync_failed_dialog():
    dialog = ctk.CTkToplevel(root)
    dialog.title("Sync Failed")
    apply_window_icon(dialog)
    dialog.resizable(False, False)
    center_window(dialog, root, 360, 200)
    
    dialog.grab_set()

    ctk.CTkLabel(
        dialog,
        text="Could not sync with the light.",
        font=ctk.CTkFont(size=15, weight="bold"),
    ).pack(pady=(20, 6))

    ctk.CTkLabel(
        dialog,
        text="Check the IP address, power, and network,\nthen try again.\nThe light also sometimes just doesn't respond even if on.\nIn this case, keep trying. This is a known issue. ",
        justify="center",
    ).pack(pady=(0, 14))

    btn_frame = ctk.CTkFrame(
        dialog,
        fg_color="transparent"
    )
    btn_frame.pack(pady=10)


    ctk.CTkButton(
        btn_frame,
        text="Try Again",
        fg_color=accent_color,
        hover_color=hex_add_24(accent_color),
        command=lambda: (
            dialog.destroy(),
            root.after(100, sync_from_light),
        ),
    ).pack(side="left", padx=8)

    ctk.CTkButton(
        btn_frame,
        text="OK",
        fg_color="#444444",
        hover_color="#555555",
        command=dialog.destroy,
    ).pack(side="left", padx=8)

def sync_from_light():
    ip = ip_var.get().strip()

    if not ip:
        show_no_ip_dialog()
        return
  
    global current_state, current_rgb, current_brightness, current_temp
    global current_mode, is_syncing, connected
    global device_rgb, device_temp
    global current_h, current_s, current_v, hsv_authoritative
    global selected_preset_name

    state_label.configure(text="State: Syncing…")
    root.update_idletasks()

    result = get_pilot()
    if not result:
        state_label.configure(text="State: Disconnected")
        open_sync_failed_dialog()
        return

    is_syncing = True
    try:
        selected_preset_name = None

        current_state = bool(result.get("state", True))
        set_power_ui(current_state)

        old_brightness = current_brightness
        dim = result.get("dimming")
        if dim is not None:
            current_brightness = int(dim)

        r = result.get("r")
        g = result.get("g")
        b = result.get("b")
        temp = result.get("temp")

        if r is not None and g is not None and b is not None and (r or g or b):
            current_mode = "rgb"
            mode_segment.set("RGB")

            current_rgb = (int(r), int(g), int(b))
            device_rgb = current_rgb
            save_last_rgb(device_rgb)

            hsv_authoritative = False
            h, s, v = colorsys.rgb_to_hsv(
                current_rgb[0] / 255,
                current_rgb[1] / 255,
                current_rgb[2] / 255,
            )
            current_h, current_s, current_v = h, s, v

        elif temp is not None:
            current_mode = "white"
            mode_segment.set("White")

            old_temp = current_temp
            current_temp = max(2200, min(6500, int(temp)))
            device_temp = current_temp

            temp_varue_label.configure(text=f"{current_temp}K")
            redraw_temp_slider()

            animate_label_change(
                temp_varue_label,
                old_temp,
                current_temp,
                suffix="K",
            )

        update_brightness_source_from_device()
        redraw_brightness_slider()

        if current_mode == "rgb":
            sync_all_color_controls()

        animate_label_change(
            brightness_varue_label,
            old_brightness,
            current_brightness,
            suffix="%",
        )

        state_label.configure(
            text=f"State: {'ON' if current_state else 'OFF'}"
        )

        update_control_states()
        rebuild_preset_buttons()

        connected = True
        update_state_label(True)
        save_last_ip(ip_var.get())

    finally:
        is_syncing = False

# ---------- GUI (customtkinter) ----------

ctk.set_appearance_mode("dark")

root = ctk.CTk()
root.title("kek's WiZ Light Controller")
root.geometry("609x947")
root.resizable(False, False)
try:
    root.iconbitmap(resource_path("assets/app_icon.ico"))
except Exception:
    try:
        icon_image = tk.PhotoImage(
            file=resource_path("assets/app_icon.png")
        )
        root.iconphoto(True, icon_image)
    except Exception:
        pass

ip_frame = ctk.CTkFrame(root)
ip_frame.pack(padx=10, pady=10, fill="x")

ip_label = ctk.CTkLabel(ip_frame, text="WiZ IP:")
ip_label.pack(side="left", padx=(8, 4), pady=8)

load_last_ip()
load_presets()
load_settings()
apply_theme_colors()

ip_var = tk.StringVar(value=DEFAULT_IP)

ip_var = tk.StringVar(value=DEFAULT_IP)
ip_entry = ctk.CTkEntry(ip_frame, textvariable=ip_var, width=98)
ip_entry.pack(side="left", padx=(0, 10))

discover_btn = ctk.CTkButton(
    ip_frame,
    image=discover_icon,
    text="",
    width=24,
    height=24,
    corner_radius=0,
    fg_color="#2b2b2b",
    hover_color="#2b2b2b",
    command=open_discovery_dialog,
)
discover_btn.pack(side="left", padx=(0, 6))
discover_btn.bind(
    "<Enter>",
    lambda e: discover_btn.configure(image=discover_icon_hover)
)
discover_btn.bind(
    "<Leave>",
    lambda e: discover_btn.configure(image=discover_icon)
)

ip_help_btn = ctk.CTkButton(
    ip_frame,
    image=ip_help_icon,
    text="",
    width=24,
    height=24,
    corner_radius=0,
    fg_color="#2b2b2b",
    hover_color="#2b2b2b",
    command=open_ip_help_dialog,
)
ip_help_btn.pack(side="left")
ip_help_btn.bind(
    "<Enter>",
    lambda e: ip_help_btn.configure(image=ip_help_icon_hover)
)
ip_help_btn.bind(
    "<Leave>",
    lambda e: ip_help_btn.configure(image=ip_help_icon)
)


sync_button = ctk.CTkButton(
    ip_frame,
    text="Sync from Light",
    command=sync_from_light,
    fg_color=accent_color,
    hover_color=hex_add_24(accent_color),
)
sync_button.pack(side="right", padx=8, pady=8)

state_label = ctk.CTkLabel(
    ip_frame,
    text="State: Disconnected",
    width=110,
    anchor="center"
)
state_label.pack(side="right", padx=(10, 6))
update_state_label(False)

mode_power_frame = ctk.CTkFrame(root)
mode_power_frame.pack(padx=10, pady=8, fill="x")

power_frame = ctk.CTkFrame(mode_power_frame, fg_color="transparent")
power_frame.pack(side="left")

ctk.CTkLabel(
    power_frame,
    text="Power:",
).pack(side="left", padx=(8, 6), pady=8)

def on_power_change(value: str):
    if value == "ON":
        turn_on()
        set_power_ui(True)
    else:
        turn_off()
        set_power_ui(False)

power_segment = ctk.CTkSegmentedButton(
    power_frame,
    values=["ON", "OFF"],
    command=on_power_change,
    selected_color=accent_color,
    selected_hover_color=hex_add_24(accent_color),
    unselected_hover_color="#4a4a4a",
)
power_segment.pack(side="left", pady=8)
power_segment.set("OFF")

mode_frame = ctk.CTkFrame(mode_power_frame, fg_color="transparent")
mode_frame.pack(side="left", padx=(18, 0))

ctk.CTkLabel(
    mode_frame,
    text="Mode:",
).pack(side="left", padx=(0, 6), pady=8)

def on_mode_change(value: str):
    if value == "RGB":
        set_mode_rgb()
    else:
        set_mode_white()

mode_segment = ctk.CTkSegmentedButton(
    mode_frame,
    values=["RGB", "White"],
    command=on_mode_change,
    selected_color=accent_color,
    selected_hover_color=hex_add_24(accent_color),
    unselected_hover_color="#4a4a4a",
)
mode_segment.pack(side="left", pady=8)
mode_segment.set("RGB" if current_mode == "rgb" else "White")

settings_frame = ctk.CTkFrame(mode_power_frame, fg_color="transparent")
settings_frame.pack(side="right", padx=(0, 18))

settings_button = ctk.CTkButton(
    settings_frame,
    image=settings_icon,
    text="",
    width=24,
    height=24,
    corner_radius=0,
    fg_color="#2b2b2b",
    hover_color="#2b2b2b",
    command=open_settings_dialog,
)
settings_button.pack(pady=6)
settings_button.bind(
    "<Enter>",
    lambda e: settings_button.configure(image=settings_icon_hover)
)

settings_button.bind(
    "<Leave>",
    lambda e: settings_button.configure(image=settings_icon)
)

preset_label = ctk.CTkLabel(root, text="Presets", anchor="center", justify="center")
preset_label.pack(padx=10, pady=(0, 4), fill="x")

preset_frame = ctk.CTkFrame(root)
preset_frame.pack(padx=10, pady=(0, 10), fill="x")

save_preset_button = ctk.CTkButton(
    root,
    text="Save Preset",
    command=save_current_preset,
    fg_color=accent_color,
    hover_color=hex_add_24(accent_color),
)
save_preset_button.pack(padx=10, pady=(4, 8))
preset_buttons = {}

def rebuild_preset_buttons():
    for btn in preset_buttons.values():
        btn.destroy()
    preset_buttons.clear()

    mode_presets = presets.get(current_mode)
    if not mode_presets:
        return

    for i, name in enumerate(mode_presets.keys()):
        preset = mode_presets[name]

        is_selected = (name == selected_preset_name)
        is_matching = preset_matches_current_state(preset)

        if is_selected or is_matching:
            fg = highlight_color
            hover = hex_add_24(highlight_color)
        else:
            fg = accent_color
            hover = hex_add_24(accent_color)

        btn = ctk.CTkButton(
            preset_frame,
            text=name,
            width=90,
            fg_color=fg,
            hover_color=hover,
            command=lambda n=name: apply_preset_by_name(n),
        )
        btn.grid(row=0, column=i, padx=4, pady=4)

        if preset["mode"] == "rgb":
            r, g, b = preset["r"], preset["g"], preset["b"]
            tooltip_text = f"RGB: {r}, {g}, {b}\nBrightness: {preset['brightness']}%"
        else:
            tooltip_text = f"Temp: {preset['temp']}K\nBrightness: {preset['brightness']}%"

        btn.bind(
        "<Button-3>",
        lambda e, m=current_mode, n=name: open_preset_actions_dialog(m, n)
    )

brightness_frame = ctk.CTkFrame(root)
brightness_frame.pack(padx=10, pady=8, fill="x")

ctk.CTkLabel(
    brightness_frame,
    text="Brightness",
).pack(anchor="w", padx=8, pady=(8, 2))

brightness_canvas = tk.Canvas(
    brightness_frame,
    height=HUE_SLIDER_HEIGHT,
    highlightthickness=0,
    bd=0,
    bg=resolve_ctk_color(frame_bg),
)
brightness_canvas.pack(padx=8, fill="x")
brightness_canvas.bind("<Button-1>", on_brightness_canvas_event)
brightness_canvas.bind("<B1-Motion>", on_brightness_canvas_event)
brightness_canvas.bind("<Configure>", lambda e: redraw_brightness_slider())

brightness_varue_label = ctk.CTkLabel(
    brightness_frame,
    text=f"{current_brightness}%",
)
brightness_varue_label.pack(anchor="e", padx=8)

brightness_thumb = None

color_picker_frame = ctk.CTkFrame(root)
picker_container = ctk.CTkFrame(color_picker_frame)
picker_container.pack(fill="both", expand=True, padx=10, pady=10)

wheel_size = 240

wheel_bg = picker_container.cget("fg_color")
if isinstance(wheel_bg, (list, tuple)):
    wheel_bg = wheel_bg[0] if ctk.get_appearance_mode() == "Light" else wheel_bg[1]

wheel_canvas = tk.Canvas(
    picker_container,
    width=wheel_size,
    height=wheel_size,
    highlightthickness=0,
    bd=0,
    bg=wheel_bg,
)
wheel_canvas.pack(pady=(12, 0))

wheel_image = generate_color_wheel(wheel_size)
wheel_canvas.wheel_img = wheel_image

wheel_canvas.create_image(
    wheel_size // 2,
    wheel_size // 2,
    image=wheel_image
)

def on_wheel_press(event):
    global wheel_dragging

    wheel_dragging = True

    wheel_canvas.grab_set()

    root.bind("<B1-Motion>", on_wheel_global_drag)

    update_from_wheel(event.x, event.y)

def on_wheel_global_drag(event):
    if not wheel_dragging:
        return

    x = wheel_canvas.winfo_pointerx() - wheel_canvas.winfo_rootx()
    y = wheel_canvas.winfo_pointery() - wheel_canvas.winfo_rooty()

    update_from_wheel(x, y)

def on_wheel_release(event):
    global wheel_dragging, dragging_wheel, wheel_drag_active

    wheel_dragging = False
    dragging_wheel = False
    wheel_drag_active = False

    commit_rgb_preview()

    root.unbind("<B1-Motion>")

    try:
        wheel_canvas.grab_release()
    except tk.TclError:
        pass

wheel_canvas.bind("<Button-1>", on_wheel_press)
wheel_canvas.bind("<ButtonRelease-1>", on_wheel_release)

def make_rgb_slider(label_text, var):
    frame = ctk.CTkFrame(
        picker_container,
        fg_color=SLIDER_BG_COLOR,
        corner_radius=8
    )
    frame.pack(fill="x", pady=6)

    ctk.CTkLabel(
        frame,
        text=label_text,
        width=36
    ).pack(side="left", padx=(8, 4))

    canvas = tk.Canvas(
        frame,
        height=16,
        highlightthickness=0,
        bd=0,
        bg=SLIDER_BG_COLOR,
    )
    canvas.pack(side="left", padx=6, fill="x", expand=True)

    entry = ctk.CTkEntry(
        frame,
        textvariable=var,
        width=56,
        justify="center"
    )
    entry.pack(side="right", padx=(4, 8))

    return canvas, entry


r_var = ctk.StringVar(value="0")
g_var = ctk.StringVar(value="0")
b_var = ctk.StringVar(value="0")

r_canvas, r_entry = make_rgb_slider("R", r_var)
g_canvas, g_entry = make_rgb_slider("G", g_var)
b_canvas, b_entry = make_rgb_slider("B", b_var)

r_entry.bind("<KeyRelease>", lambda e: commit_rgb_entry(r_var, "r"))
g_entry.bind("<KeyRelease>", lambda e: commit_rgb_entry(g_var, "g"))
b_entry.bind("<KeyRelease>", lambda e: commit_rgb_entry(b_var, "b"))

r_entry.bind("<FocusOut>", lambda e: on_rgb_entry(r_var, "r"))
g_entry.bind("<FocusOut>", lambda e: on_rgb_entry(g_var, "g"))
b_entry.bind("<FocusOut>", lambda e: on_rgb_entry(b_var, "b"))

r_thumb = None
g_thumb = None
b_thumb = None
r_canvas.bind("<Button-1>", lambda e: on_rgb_canvas_event(r_canvas, "r", e))
r_canvas.bind("<B1-Motion>", lambda e: on_rgb_canvas_event(r_canvas, "r", e))
r_canvas.bind("<ButtonRelease-1>", lambda e: commit_rgb_preview())
g_canvas.bind("<Button-1>", lambda e: on_rgb_canvas_event(g_canvas, "g", e))
g_canvas.bind("<B1-Motion>", lambda e: on_rgb_canvas_event(g_canvas, "g", e))
g_canvas.bind("<ButtonRelease-1>", lambda e: commit_rgb_preview())
b_canvas.bind("<Button-1>", lambda e: on_rgb_canvas_event(b_canvas, "b", e))
b_canvas.bind("<B1-Motion>", lambda e: on_rgb_canvas_event(b_canvas, "b", e))
b_canvas.bind("<ButtonRelease-1>", lambda e: commit_rgb_preview())

h_var = ctk.StringVar(value="0")

hue_slider_frame = ctk.CTkFrame(
    picker_container,
    fg_color=SLIDER_BG_COLOR,
    corner_radius=8
)
hue_slider_frame.pack(fill="x", pady=6)

ctk.CTkLabel(
    hue_slider_frame,
    text="Hue",
    width=36
).pack(side="left", padx=(8, 4))

if isinstance(frame_bg, (list, tuple)):
    frame_bg = frame_bg[0] if ctk.get_appearance_mode() == "Light" else frame_bg[1]

hue_canvas = tk.Canvas(
    hue_slider_frame,
    height=HUE_SLIDER_HEIGHT,
    highlightthickness=0,
    bd=0,
    bg=frame_bg,
)
hue_canvas.pack(side="left", padx=6, fill="x", expand=True)

hue_value_entry = ctk.CTkEntry(
    hue_slider_frame,
    textvariable=h_var,
    width=56,
    justify="center",
)
hue_value_entry.pack(side="right", padx=(4, 8))

hue_thumb = None

hue_canvas.bind("<Button-1>", on_hue_slider_event)
hue_canvas.bind("<B1-Motion>", on_hue_slider_event)
hue_canvas.bind("<Configure>", redraw_hue_gradient)

s_var = ctk.StringVar(value="0")

sat_slider_frame = ctk.CTkFrame(
    picker_container,
    fg_color=SLIDER_BG_COLOR,
    corner_radius=8
)
sat_slider_frame.pack(fill="x", pady=6)

ctk.CTkLabel(
    sat_slider_frame,
    text="Sat",
    width=36
).pack(side="left", padx=(8, 4))

sat_canvas = tk.Canvas(
    sat_slider_frame,
    height=HUE_SLIDER_HEIGHT,
    highlightthickness=0,
    bd=0,
    bg=frame_bg,
)
sat_canvas.pack(side="left", padx=6, fill="x", expand=True)

sat_entry = ctk.CTkEntry(
    sat_slider_frame,
    textvariable=s_var,
    width=56,
    justify="center",
)
sat_entry.pack(side="right", padx=(4, 8))

sat_thumb = None

sat_canvas.bind("<Button-1>", on_sat_slider_event)
sat_canvas.bind("<B1-Motion>", on_sat_slider_event)

v_var = ctk.StringVar(value="0")

val_slider_frame = ctk.CTkFrame(
    picker_container,
    fg_color=SLIDER_BG_COLOR,
    corner_radius=8
)
val_slider_frame.pack(fill="x", pady=6)

ctk.CTkLabel(
    val_slider_frame,
    text="Val",
    width=36
).pack(side="left", padx=(8, 4))

val_canvas = tk.Canvas(
    val_slider_frame,
    height=HUE_SLIDER_HEIGHT,
    highlightthickness=0,
    bd=0,
    bg=frame_bg,
)
val_canvas.pack(side="left", padx=6, fill="x", expand=True)

val_entry = ctk.CTkEntry(
    val_slider_frame,
    textvariable=v_var,
    width=56,
    justify="center",
)
val_entry.pack(side="right", padx=(4, 8))

hue_value_entry.bind("<KeyRelease>", lambda e: commit_hsv_entry(h_var, "h"))
sat_entry.bind("<KeyRelease>", lambda e: commit_hsv_entry(s_var, "s"))
val_entry.bind("<KeyRelease>", lambda e: commit_hsv_entry(v_var, "l"))

hue_value_entry.bind("<FocusOut>", lambda e: on_hsv_entry(h_var, "h"))
sat_entry.bind("<FocusOut>", lambda e: on_hsv_entry(s_var, "s"))
val_entry.bind("<FocusOut>", lambda e: on_hsv_entry(v_var, "l"))

val_canvas.bind("<Button-1>", on_val_slider_event)
val_canvas.bind("<B1-Motion>", on_val_slider_event)
val_thumb = None

hex_var = ctk.StringVar(value="#FFFFFF")
hex_entry_frame = ctk.CTkFrame(
    picker_container,
    fg_color="transparent"
)
hex_entry_frame.pack(pady=(6, 8))

hex_entry = ctk.CTkEntry(
    hex_entry_frame,
    textvariable=hex_var,
    width=120,
    justify="center"
)
hex_entry.pack()
hex_var.trace_add("write", on_hex_change)

apply_color_btn = ctk.CTkButton(
    picker_container,
    text="Apply Color",
    fg_color=accent_color,
    hover_color=hex_add_24(accent_color),
)
apply_color_btn.pack(pady=(0, 6))
apply_color_btn.configure(command=apply_color_from_controls)

temp_frame = ctk.CTkFrame(root)
temp_frame.pack(padx=10, pady=8, fill="x")

ctk.CTkLabel(
    temp_frame,
    text="White Temperature (Warm ↔ Cool)",
).pack(anchor="w", padx=8, pady=(8, 2))

temp_canvas = tk.Canvas(
    temp_frame,
    height=HUE_SLIDER_HEIGHT,
    highlightthickness=0,
    bd=0,
    bg=resolve_ctk_color(frame_bg),
)
temp_canvas.pack(padx=8, fill="x")

temp_varue_label = ctk.CTkLabel(
    temp_frame,
    text=f"{current_temp}K",
)
temp_varue_label.pack(anchor="e", padx=8)

temp_thumb = None
temp_canvas.bind("<Button-1>", on_temp_canvas_event)
temp_canvas.bind("<B1-Motion>", on_temp_canvas_event)
temp_canvas.bind("<Configure>", lambda e: redraw_temp_slider())
temp_canvas.bind("<ButtonRelease-1>", lambda e: rebuild_preset_buttons())
brightness_canvas.bind("<ButtonRelease-1>", lambda e: rebuild_preset_buttons())

def update_control_states():
    if not current_state:
        return

    preset_label.pack(padx=10, pady=(0, 4), fill="x")
    preset_frame.pack(padx=10, pady=(0, 10), fill="x")
    save_preset_button.pack(padx=10, pady=(4, 8))
    brightness_frame.pack(padx=10, pady=8, fill="x")

    if current_mode == "rgb":
        temp_frame.pack_forget()
        color_picker_frame.pack(padx=10, pady=8, fill="x")
        root.geometry("609x947")
    else:
        color_picker_frame.pack_forget()
        temp_frame.pack(padx=10, pady=8, fill="x")
        root.geometry("609x441")
update_control_states()
rebuild_preset_buttons()
update_color_preview()
if auto_sync_enabled:
    root.after(200, sync_from_light)
root.mainloop()
apply_theme_colors()
