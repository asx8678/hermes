//! Color palette for the TUI — **Tokyo Night** ("Night").
//!
//! Ported from the droid (`roidrs-tui`) theme so the hermes TUI shares its look.
//! The renderer never paints a full-screen background, so the terminal's own
//! background shows through; only `user_bg` tints the user-message gutter.

use ratatui::style::Color;

/// Build a `Color` from a `0xRRGGBB` literal.
const fn rgb(hex: u32) -> Color {
    Color::Rgb(
        (hex >> 16) as u8,
        ((hex >> 8) & 0xff) as u8,
        (hex & 0xff) as u8,
    )
}

/// Semantic UI colors. `Copy` so it can be threaded freely through render helpers.
#[derive(Debug, Clone, Copy)]
pub struct Palette {
    pub primary: Color,   // accent (cornflower blue) — borders edges/titles/active accents
    pub border: Color,    // box borders
    pub text: Color,      // primary foreground
    pub secondary: Color, // secondary foreground
    pub muted: Color,     // de-emphasised / hint text
    pub success: Color,
    pub error: Color,
    pub warning: Color,
    // User message treatment
    pub user_text: Color,
    pub user_bg: Color,
    pub user_symbol: Color,
    // Tool calls
    pub tool_name: Color,
    pub tool_param: Color,
    // Selection highlight (lists/menus)
    pub sel_fg: Color,
    pub sel_bg: Color,
}

impl Palette {
    /// Tokyo Night — "Night".
    pub const DARK: Palette = Palette {
        primary: rgb(0x7aa2f7),
        border: rgb(0x414868),
        text: rgb(0xc0caf5),
        secondary: rgb(0xa9b1d6),
        muted: rgb(0x565f89),
        success: rgb(0x9ece6a),
        error: rgb(0xf7768e),
        warning: rgb(0xe0af68),
        user_text: rgb(0xc0caf5),
        user_bg: rgb(0x292e42),
        user_symbol: rgb(0x7aa2f7),
        tool_name: rgb(0x7dcfff),
        tool_param: rgb(0x565f89),
        sel_fg: rgb(0x1a1b26),
        sel_bg: rgb(0x7aa2f7),
    };

    /// Resolve the active palette, honoring `NO_COLOR` and terminal capability.
    pub fn current() -> Palette {
        // Honor NO_COLOR (https://no-color.org/).
        if std::env::var_os("NO_COLOR").is_some() {
            return Palette::no_color();
        }
        // Downsample to named colors when truecolor is unavailable.
        if !supports_truecolor() {
            return Palette::downsampled();
        }
        Palette::DARK
    }

    /// A styleless palette used when `NO_COLOR` is set.
    const fn no_color() -> Palette {
        Palette {
            primary: Color::Reset,
            border: Color::Reset,
            text: Color::Reset,
            secondary: Color::Reset,
            muted: Color::Reset,
            success: Color::Reset,
            error: Color::Reset,
            warning: Color::Reset,
            user_text: Color::Reset,
            user_bg: Color::Reset,
            user_symbol: Color::Reset,
            tool_name: Color::Reset,
            tool_param: Color::Reset,
            sel_fg: Color::Reset,
            sel_bg: Color::Reset,
        }
    }

    /// A named-color fallback for terminals without truecolor support.
    const fn downsampled() -> Palette {
        Palette {
            primary: Color::LightBlue,
            border: Color::DarkGray,
            text: Color::White,
            secondary: Color::Gray,
            muted: Color::DarkGray,
            success: Color::Green,
            error: Color::Red,
            warning: Color::Yellow,
            user_text: Color::White,
            user_bg: Color::DarkGray,
            user_symbol: Color::LightBlue,
            tool_name: Color::Cyan,
            tool_param: Color::DarkGray,
            sel_fg: Color::Black,
            sel_bg: Color::LightBlue,
        }
    }
}

fn supports_truecolor() -> bool {
    std::env::var("COLORTERM")
        .map(|c| c == "truecolor" || c == "24bit")
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgb_unpacks_hex() {
        assert_eq!(rgb(0x7aa2f7), Color::Rgb(0x7a, 0xa2, 0xf7));
        assert_eq!(rgb(0x000000), Color::Rgb(0, 0, 0));
    }

    #[test]
    fn dark_uses_tokyo_night_accent() {
        assert_eq!(Palette::DARK.primary, rgb(0x7aa2f7));
    }

    #[test]
    fn no_color_is_styleless() {
        assert_eq!(Palette::no_color().primary, Color::Reset);
    }

    #[test]
    fn downsampled_uses_named_colors() {
        let p = Palette::downsampled();
        assert!(!matches!(p.primary, Color::Rgb(_, _, _)));
        assert_eq!(p.primary, Color::LightBlue);
        assert_eq!(p.error, Color::Red);
    }
}
