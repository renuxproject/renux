--
-- SPDX-License-Identifier: MPL-2.0
--
-- Copyright (c) 2026 Renan Lucas Vieira Hilário
-- Copyright (c) 2026 The Renux Project
--
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.
--
-- Renux's brand and logo in the boot menu (loader_brand="renux",
-- loader_logo="renux", the defaults of /boot/defaults/loader.conf): its
-- name and its logo, as images on a framebuffer (UEFI's), as text on
-- other consoles.  The images are the website's logos
-- (renuxproject.github.io, logos/), made with:
--
--   rsvg-convert -w 240 -h 240 main-logo.svg -o renux-logo.png
--   rsvg-convert -w 1024 -h 1024 main-logo-transparent-white.svg |
--       magick - -trim +repage -resize x84 -background none \
--       -gravity center -extent x100 renux-brand-rev.png
--

return {
	brand = {
		ascii = {
			image = {
			"  ____                        ",
			" |  _ \\ ___ _ __  _   ___  __",
			" | |_) / _ \\ '_ \\| | | \\ \\/ /",
			" |  _ <  __/ | | | |_| |>  < ",
			" |_| \\_\\___|_| |_|\\__,_/_/\\_\\",
			},
		},
		fb = {
			image = "/boot/images/renux-brand-rev.png",
		},
	},
	logo = {
		ascii = {
			image = {
			"\027[32m.------------------------.",
			"|\027[32;1m                        \027[32m|",
			"|\027[32;1m                        \027[32m|",
			"|\027[32;1m                        \027[32m|",
			"|\027[33;1m     R  e  n  u  x      \027[32m|",
			"|\027[32;1m                        \027[32m|",
			"|\027[32;1m                        \027[32m|",
			"|\027[32;1m                        \027[32m|",
			"'------------------------'\027[m",
			},
			requires_color = true,
			shift = {x = 4, y = 2},
		},
		fb = {
			image = "/boot/images/renux-logo.png",
			width = 14,
			shift = {x = 3, y = -1},
		},
	},
}
