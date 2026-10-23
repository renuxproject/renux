/*-
 * SPDX-License-Identifier: MPL-2.0
 *
 * Copyright (c) 2026 Renan Lucas Vieira Hilário
 * Copyright (c) 2026 The Renux Project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * The xterm screen features vt(4) lacked, which full-screen programs and
 * clear(1) rely on:
 *
 *   - the alternate screen (DECSET 47, 1047 and 1049): htop, vi, less and
 *     the like draw on a screen of their own, and when they leave, the
 *     screen they were started from comes back as it was;
 *   - erase saved lines (ED 3, "\e[3J"): clear(1) empties the history
 *     too, so scrolling back does not bring the old text again.
 *
 * teken(4) recognizes the sequences and asks vt_core through tf_param
 * (TP_ALTSCREEN, TP_CLEARHISTORY); this file does the work on the
 * window's buffer.
 */

#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/lock.h>
#include <sys/malloc.h>
#include <sys/mutex.h>
#include <sys/systm.h>

#include <dev/vt/vt.h>

static MALLOC_DEFINE(M_VTSCREEN, "vtscreen", "vt saved screens");

/* A window's normal screen, kept while the alternate screen is shown. */
struct vt_screen {
	term_char_t	*vs_cells;	/* The rows, one after another. */
	term_pos_t	 vs_size;	/* The screen's size then. */
	unsigned int	 vs_history_size;
	unsigned int	 vs_roffset;
	unsigned int	 vs_curroffset;
	int		 vs_history_full;
};

static struct vt_screen vt_screens[VT_MAXWINDOWS];

/* Copy the screen's rows into cells (save), or cells back into them. */
static void
vt_screen_copy(struct vt_buf *vb, term_char_t *cells, term_pos_t size,
    int save)
{
	term_char_t *row;
	unsigned int r, rows, cols;

	rows = MIN(size.tp_row, vb->vb_scr_size.tp_row);
	cols = MIN(size.tp_col, vb->vb_scr_size.tp_col);
	for (r = 0; r < rows; r++) {
		row = vb->vb_rows[(vb->vb_curroffset + r) %
		    VTBUF_MAX_HEIGHT(vb)];
		if (save)
			memcpy(&cells[r * size.tp_col], row,
			    cols * sizeof(term_char_t));
		else
			memcpy(row, &cells[r * size.tp_col],
			    cols * sizeof(term_char_t));
	}
}

/* Mark the whole screen to be drawn again. */
static void
vt_screen_dirty(struct vt_buf *vb)
{
	term_rect_t r;

	r.tr_begin.tp_row = r.tr_begin.tp_col = 0;
	r.tr_end = vb->vb_scr_size;
	vtbuf_dirty(vb, &r);
}

/* Show the alternate screen (on), or the normal screen again. */
void
vt_screen_alternate(struct vt_window *vw, int on)
{
	struct vt_buf *vb;
	struct vt_screen *vs;
	term_char_t *cells;

	if (vw->vw_number >= VT_MAXWINDOWS)
		return;
	vb = &vw->vw_buf;
	vs = &vt_screens[vw->vw_number];

	if (on) {
		if (vs->vs_cells != NULL)
			return;
		cells = malloc(vb->vb_scr_size.tp_row * vb->vb_scr_size.tp_col *
		    sizeof(term_char_t), M_VTSCREEN, M_NOWAIT);
		if (cells == NULL)
			return;
		vtbuf_lock(vb);
		vs->vs_cells = cells;
		vs->vs_size = vb->vb_scr_size;
		vs->vs_history_size = vb->vb_history_size;
		vs->vs_roffset = vb->vb_roffset;
		vs->vs_curroffset = vb->vb_curroffset;
		vs->vs_history_full = vb->vb_flags & VBF_HISTORY_FULL;
		vt_screen_copy(vb, cells, vs->vs_size, 1);
		vtbuf_unlock(vb);
		return;
	}

	if (vs->vs_cells == NULL)
		return;
	vtbuf_lock(vb);
	/*
	 * Lines the alternate screen scrolled are not history: go back to
	 * where the normal screen was, unless the buffer has changed shape.
	 */
	if (vb->vb_history_size == vs->vs_history_size &&
	    vb->vb_scr_size.tp_row == vs->vs_size.tp_row &&
	    vb->vb_scr_size.tp_col == vs->vs_size.tp_col) {
		vb->vb_roffset = vs->vs_roffset;
		vb->vb_curroffset = vs->vs_curroffset;
		vb->vb_flags = (vb->vb_flags & ~VBF_HISTORY_FULL) |
		    vs->vs_history_full;
	}
	vt_screen_copy(vb, vs->vs_cells, vs->vs_size, 0);
	vt_screen_dirty(vb);
	vtbuf_unlock(vb);
	free(vs->vs_cells, M_VTSCREEN);
	vs->vs_cells = NULL;
}

/* Erase the history, and keep what the screen shows. */
void
vt_screen_clearhistory(struct vt_window *vw)
{
	struct vt_buf *vb;
	term_char_t *cells;
	term_pos_t size;

	vb = &vw->vw_buf;
	size = vb->vb_scr_size;
	cells = malloc(size.tp_row * size.tp_col * sizeof(term_char_t),
	    M_VTSCREEN, M_NOWAIT);

	if (cells != NULL) {
		vtbuf_lock(vb);
		vt_screen_copy(vb, cells, size, 1);
		vtbuf_unlock(vb);
	}
	vtbuf_clearhistory(vb);
	vtbuf_lock(vb);
	if (cells != NULL)
		vt_screen_copy(vb, cells, size, 0);
	vt_screen_dirty(vb);
	vtbuf_unlock(vb);
	free(cells, M_VTSCREEN);
}
