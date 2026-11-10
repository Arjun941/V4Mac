// muguet - menu.rs
// In-game mod menu: ` (backtick, above Tab) opens it, arrow keys move, Enter selects, Backspace goes back.
// Single player only (disabled while connected to a multiplayer server).

use super::{b, delete_vehicle, f, i, model_ready, Cmd, S_NAME, S_TEXT};
use crate::proto;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub static OPEN: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Copy, PartialEq)]
enum Nav {
    Up,
    Down,
    Select,
    Back,
}

static QUEUE: Mutex<Vec<Nav>> = Mutex::new(Vec::new());

pub fn is_open() -> bool {
    OPEN.load(Ordering::Relaxed)
}

pub fn key(code: &str) {
    if std::env::var("MUGUET_MODMENU").map(|v| v == "0").unwrap_or(false) {
        return;
    }
    if code == "Backquote" {
        if super::net().is_none() {
            OPEN.fetch_xor(true, Ordering::Relaxed);
        }
        return;
    }
    if !is_open() {
        return;
    }
    let nav = match code {
        "ArrowUp" => Nav::Up,
        "ArrowDown" => Nav::Down,
        "Enter" | "NumpadEnter" | "ArrowRight" => Nav::Select,
        "Backspace" | "ArrowLeft" | "Escape" => Nav::Back,
        _ => return,
    };
    let mut q = QUEUE.lock().unwrap();
    if q.len() < 16 {
        q.push(nav);
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Page {
    Main,
    Player,
    Vehicles,
    VehList(usize),
    Vehicle,
    Teleport,
    World,
}

const CATEGORIES: &[(&str, &[&str])] = &[
    ("Super", &["adder", "zentorno", "t20", "osiris", "entityxf", "turismor", "vacca", "infernus", "cheetah", "reaper"]),
    ("Sports", &["elegy2", "jester", "massacro", "carbonizzare", "comet2", "banshee", "buffalo", "feltzer2", "ninef", "surano"]),
    ("Muscle", &["dominator", "gauntlet", "sabregt", "vigero", "ruiner", "stalion", "blade", "buccaneer"]),
    ("Sedans & SUVs", &["oracle", "schafter2", "sultan", "baller", "granger", "landstalker", "cognoscenti", "kuruma"]),
    ("Bikes", &["bati", "akuma", "sanchez", "hakuchou", "double", "faggio", "bmx", "scorcher"]),
    ("Helicopters", &["buzzard", "maverick", "frogger", "annihilator", "savage", "swift"]),
    ("Planes", &["luxor", "shamal", "cuban800", "titan", "duster", "lazer", "hydra", "jet"]),
    ("Boats", &["seashark", "jetmax", "dinghy", "marquis", "speeder", "tropic"]),
    ("Emergency & Military", &["police", "police2", "policeb", "fbi", "firetruk", "ambulance", "rhino", "insurgent", "barracks", "crusader"]),
    ("Misc", &["monster", "tractor", "dump", "bulldozer", "mower", "bus", "taxi", "stretch", "blimp"]),
];

const PLACES: &[(&str, [f32; 3])] = &[
    ("Michael's house", [-813.0, 178.0, 72.5]),
    ("Legion Square", [195.0, -934.0, 30.7]),
    ("Los Santos Airport", [-1336.0, -3044.0, 13.95]),
    ("Maze Bank roof", [-75.0, -818.0, 326.2]),
    ("Vinewood sign", [711.0, 1198.0, 348.5]),
    ("Mount Chiliad summit", [450.0, 5566.0, 806.2]),
    ("Fort Zancudo", [-2047.0, 3132.0, 32.8]),
    ("Sandy Shores", [1850.0, 3700.0, 34.0]),
    ("Paleto Bay", [-275.0, 6635.0, 7.5]),
    ("Del Perro Beach", [-1850.0, -1200.0, 13.2]),
];

const TIMES: &[(&str, i32)] = &[("Morning (08:00)", 8), ("Noon (12:00)", 12), ("Evening (19:00)", 19), ("Midnight (00:00)", 0)];
const WEATHERS: &[(&str, &str)] = &[("Clear", "CLEAR"), ("Extra sunny", "EXTRASUNNY"), ("Cloudy", "CLOUDS"), ("Overcast", "OVERCAST"), ("Rain", "RAIN"), ("Thunder", "THUNDER"), ("Fog", "FOGGY"), ("Snow", "SNOW")];

struct Menu {
    page: Page,
    sel: usize,
    god: bool,
    god_applied: bool,
    no_cops: bool,
    veh_god: bool,
    slowmo: bool,
    pending: Option<(u32, String, Instant)>,
    last_spawn: i32,
    toast: Option<(String, Instant)>,
}

static MENU: Mutex<Menu> = Mutex::new(Menu { page: Page::Main, sel: 0, god: false, god_applied: false, no_cops: false, veh_god: false, slowmo: false, pending: None, last_spawn: 0, toast: None });

fn onoff(v: bool) -> &'static str {
    if v { "ON" } else { "OFF" }
}

fn items(m: &Menu) -> (&'static str, Vec<String>) {
    match m.page {
        Page::Main => ("MOD MENU", ["Player", "Spawn vehicle", "Current vehicle", "Teleport", "World"].map(String::from).to_vec()),
        Page::Player => (
            "PLAYER",
            vec![format!("God mode: {}", onoff(m.god)), "Heal".into(), "Full armor".into(), "Clear wanted level".into(), "Raise wanted level".into(), format!("Never wanted: {}", onoff(m.no_cops))],
        ),
        Page::Vehicles => ("SPAWN VEHICLE", CATEGORIES.iter().map(|(n, _)| n.to_string()).collect()),
        Page::VehList(k) => (CATEGORIES[k].0, CATEGORIES[k].1.iter().map(|n| n.to_string()).collect()),
        Page::Vehicle => ("VEHICLE", vec!["Repair".into(), "Flip upright".into(), "Boost forward".into(), format!("Indestructible: {}", onoff(m.veh_god)), "Delete vehicle".into()]),
        Page::Teleport => ("TELEPORT", PLACES.iter().map(|(n, _)| n.to_string()).collect()),
        Page::World => {
            let mut v: Vec<String> = TIMES.iter().map(|(n, _)| format!("Time: {n}")).collect();
            v.extend(WEATHERS.iter().map(|(n, _)| format!("Weather: {n}")));
            v.push(format!("Slow motion: {}", onoff(m.slowmo)));
            ("WORLD", v)
        }
    }
}

fn toast(m: &mut Menu, s: &str) {
    m.toast = Some((s.to_string(), Instant::now()));
}

fn text(c: &mut Cmd, x: f32, y: f32, s: &str, scale: f32, col: [i32; 4]) {
    let mem = c.mem();
    crate::write_bytes(mem, c.scratch + S_TEXT, b"STRING\0");
    let mut bytes: Vec<u8> = s.bytes().take(58).collect();
    bytes.push(0);
    crate::write_bytes(mem, c.scratch + S_NAME, &bytes);
    c.i("SetTextFont", &[i(4)]);
    c.i("SetTextScale", &[f(0.0), f(scale)]);
    c.i("SetTextColour", &[i(col[0]), i(col[1]), i(col[2]), i(col[3])]);
    c.i("BeginTextCommandDisplayText", &[c.ptr(S_TEXT)]);
    c.i("AddTextComponentSubStringPlayerName", &[c.ptr(S_NAME)]);
    c.i("EndTextCommandDisplayText", &[f(x), f(y), i(0)]);
}

fn rect(c: &mut Cmd, x: f32, y: f32, w: f32, h: f32, rgba: [i32; 4]) {
    super::rect(c, x + w / 2.0, y + h / 2.0, w, h, rgba);
}

fn activate(c: &mut Cmd, m: &mut Menu, ped: i32, pid: i32) {
    let idx = m.sel;
    match m.page {
        Page::Main => {
            m.page = [Page::Player, Page::Vehicles, Page::Vehicle, Page::Teleport, Page::World][idx];
            m.sel = 0;
        }
        Page::Vehicles => {
            m.page = Page::VehList(idx);
            m.sel = 0;
        }
        Page::VehList(k) => {
            let name = CATEGORIES[k].1[idx];
            m.pending = Some((proto::joaat(name), name.to_string(), Instant::now()));
            toast(m, &format!("Spawning {name}..."));
        }
        Page::Player => match idx {
            0 => m.god = !m.god,
            1 => {
                c.i("SetEntityHealth", &[i(ped), i(200), i(0)]);
                toast(m, "Healed");
            }
            2 => {
                c.i("SetPedArmour", &[i(ped), i(100)]);
                toast(m, "Armor full");
            }
            3 => {
                c.i("ClearWantedLevel", &[i(pid)]);
                toast(m, "Wanted level cleared");
            }
            4 => {
                c.i("AlterWantedLevel", &[i(pid), i(5), b(false)]);
                c.i("ApplyWantedLevelChangeNow", &[i(pid), b(false)]);
                toast(m, "Wanted level 5");
            }
            _ => m.no_cops = !m.no_cops,
        },
        Page::Vehicle => {
            let veh = if c.i("IsPedInAnyVehicle", &[i(ped), b(false)]) != 0 { c.i("GetVehiclePedIsIn", &[i(ped), b(false)]) } else { 0 };
            if veh == 0 {
                toast(m, "You are not in a vehicle");
                return;
            }
            match idx {
                0 => {
                    c.i("SetVehicleFixed", &[i(veh)]);
                    c.i("SetVehicleDeformationFixed", &[i(veh)]);
                    toast(m, "Repaired");
                }
                1 => {
                    c.i("SetVehicleOnGroundProperly", &[i(veh), f(5.0)]);
                }
                2 => {
                    c.i("SetVehicleForwardSpeed", &[i(veh), f(45.0)]);
                }
                3 => {
                    m.veh_god = !m.veh_god;
                    c.i("SetEntityInvincible", &[i(veh), b(m.veh_god)]);
                    c.i("SetVehicleStrong", &[i(veh), b(m.veh_god)]);
                }
                _ => {
                    delete_vehicle(c, veh);
                    toast(m, "Vehicle deleted");
                }
            }
        }
        Page::Teleport => {
            let to = PLACES[idx].1;
            let veh = if c.i("IsPedInAnyVehicle", &[i(ped), b(false)]) != 0 { c.i("GetVehiclePedIsIn", &[i(ped), b(false)]) } else { 0 };
            let ent = if veh != 0 { veh } else { ped };
            let p = c.vec_arg(1, to);
            c.i("SetEntityCoordsNoOffset", &[i(ent), p, b(false), b(false), b(false)]);
            toast(m, &format!("Teleported to {}", PLACES[idx].0));
        }
        Page::World => {
            if idx < TIMES.len() {
                c.i("SetClockTime", &[i(TIMES[idx].1), i(0), i(0)]);
            } else if idx < TIMES.len() + WEATHERS.len() {
                c.c_str(S_NAME, WEATHERS[idx - TIMES.len()].1);
                c.i("SetWeatherTypeNowPersist", &[c.ptr(S_NAME)]);
            } else {
                m.slowmo = !m.slowmo;
                c.i("SetTimeScale", &[f(if m.slowmo { 0.3 } else { 1.0 })]);
            }
        }
    }
}

fn spawn(c: &mut Cmd, m: &mut Menu, ped: i32) {
    let Some((model, name, since)) = m.pending.clone() else { return };
    if !model_ready(c, model) {
        if since.elapsed() > Duration::from_secs(8) {
            m.pending = None;
            toast(m, &format!("Could not load {name}"));
        }
        return;
    }
    m.pending = None;
    let pos = c.v("GetEntityCoords", &[i(ped), b(false)]);
    let h = c.f("GetEntityHeading", &[i(ped)]);
    let r = h.to_radians();
    let at = [pos[0] - 5.0 * r.sin(), pos[1] + 5.0 * r.cos(), pos[2] + 0.5];
    if m.last_spawn != 0 && c.exists(m.last_spawn) {
        delete_vehicle(c, m.last_spawn);
    }
    let p = c.vec_arg(1, at);
    let veh = c.i("CreateVehicle", &[i(model as i32), p, f(h), b(false), b(false), b(false)]);
    if veh == 0 {
        toast(m, &format!("Could not spawn {name}"));
        return;
    }
    c.i("SetVehicleOnGroundProperly", &[i(veh), f(5.0)]);
    c.i("SetVehicleEngineOn", &[i(veh), b(true), b(true), b(false)]);
    c.i("SetPedIntoVehicle", &[i(ped), i(veh), i(-1)]);
    c.i("MarkModelAsNoLongerNeeded", &[i(model as i32)]);
    m.last_spawn = veh;
    toast(m, &format!("Spawned {name}"));
}

pub fn tick(c: &mut Cmd) {
    if super::net().is_some() {
        OPEN.store(false, Ordering::Relaxed);
        return;
    }
    let mut m = MENU.lock().unwrap();
    let ped = c.i("PlayerPedId", &[]);
    if ped == 0 || !c.exists(ped) {
        return;
    }
    let pid = c.i("PlayerId", &[]);

    if m.god != m.god_applied {
        c.i("SetPlayerInvincible", &[i(pid), b(m.god)]);
        m.god_applied = m.god;
    }
    if m.no_cops {
        c.i("ClearWantedLevel", &[i(pid)]);
    }
    spawn(c, &mut m, ped);

    let nav: Vec<Nav> = std::mem::take(&mut *QUEUE.lock().unwrap());
    let open = is_open();
    if open {
        for n in nav {
            let len = items(&m).1.len();
            match n {
                Nav::Up => m.sel = (m.sel + len - 1) % len,
                Nav::Down => m.sel = (m.sel + 1) % len,
                Nav::Select => activate(c, &mut m, ped, pid),
                Nav::Back => {
                    m.page = match m.page {
                        Page::VehList(_) => Page::Vehicles,
                        Page::Main => {
                            OPEN.store(false, Ordering::Relaxed);
                            Page::Main
                        }
                        _ => Page::Main,
                    };
                    m.sel = 0;
                }
            }
        }
    }

    if let Some((_, t)) = &m.toast {
        if t.elapsed() > Duration::from_secs(3) {
            m.toast = None;
        }
    }
    if let Some((s, _)) = m.toast.clone() {
        rect(c, 0.36, 0.90, 0.28, 0.04, [0, 0, 0, 170]);
        text(c, 0.375, 0.903, &s, 0.4, [255, 255, 255, 255]);
    }

    if !is_open() {
        return;
    }
    let (title, list) = items(&m);
    const ROWS: usize = 12;
    let first = m.sel.saturating_sub(ROWS - 1).min(list.len().saturating_sub(ROWS));
    let (x, y, w, rh) = (0.03, 0.08, 0.26, 0.034);
    rect(c, x, y, w, 0.045, [20, 20, 20, 235]);
    text(c, x + 0.01, y + 0.005, title, 0.5, [120, 200, 255, 255]);
    let shown = list.len().min(ROWS);
    rect(c, x, y + 0.045, w, rh * shown as f32 + 0.01, [0, 0, 0, 175]);
    for (row, label) in list.iter().skip(first).take(ROWS).enumerate() {
        let ry = y + 0.05 + rh * row as f32;
        let selected = first + row == m.sel;
        if selected {
            rect(c, x + 0.004, ry, w - 0.008, rh - 0.002, [255, 255, 255, 235]);
        }
        let col = if selected { [0, 0, 0, 255] } else { [255, 255, 255, 255] };
        text(c, x + 0.012, ry + 0.003, label, 0.38, col);
    }
    text(c, x, y + 0.06 + rh * shown as f32, "` close  Up/Down move  Enter select  Backspace back", 0.28, [220, 220, 220, 220]);
}
