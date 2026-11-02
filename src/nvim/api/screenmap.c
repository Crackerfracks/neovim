// Drawn-position map: where buffer text was last drawn in a window.
//
// Reads only state the redraw already recorded: the per-cell virtual columns in
// ScreenGrid.vcols[] (also used for mouse clicks) and the row -> line map in
// win_T.w_lines[].  Never redraws: when the window has a pending redraw the
// result describes the previous frame and has "valid" set to false.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "nvim/api/keysets_defs.h"
#include "nvim/api/private/defs.h"
#include "nvim/api/private/dispatch.h"
#include "nvim/api/private/helpers.h"
#include "nvim/api/private/validate.h"
#include "nvim/api/screenmap.h"
#include "nvim/ascii_defs.h"
#include "nvim/buffer_defs.h"
#include "nvim/charset.h"
#include "nvim/decoration.h"
#include "nvim/globals.h"
#include "nvim/grid.h"
#include "nvim/grid_defs.h"
#include "nvim/mbyte.h"
#include "nvim/memline.h"
#include "nvim/memory_defs.h"
#include "nvim/move.h"
#include "nvim/option_vars.h"
#include "nvim/plines.h"
#include "nvim/pos_defs.h"
#include "nvim/types_defs.h"
#include "nvim/window.h"

#define SM_MAX_SEGS 8

/// Location of a w_lines[] entry in the window.
typedef struct {
  const wline_T *wl;  ///< NULL when the line is not in w_lines[]
  int row;            ///< window row of the first row of the entry (filler included)
  int text_row;       ///< window row of the first text (or fold) row
  int end_row;        ///< one past the last row, clamped to the window height
  int nfill;          ///< filler rows (virt_lines + diff filler) before the text
  int nvirt;          ///< how many of those filler rows are virt_lines
} SmEntry;

/// State kept between positions of one call, so that positions on the same line
/// in increasing column order cost O(line length) together, not each.
typedef struct {
  linenr_T lnum;        ///< line of the cached state, 0 for none
  char *line;
  CharsizeArg csarg;
  CSType cstype;
  StrCharInfo ci;       ///< character the last scan stopped at
  colnr_T vcol;         ///< vcol where "ci" starts
  bool have_cs;         ///< "cs" and "pre" are computed for "ci"
  CharSize cs;
  int pre;
  bool entry_found;     ///< w_lines[] lookup result for "lnum"
  bool entry_valid;
  SmEntry entry;
} SmLineCache;

#include "api/screenmap.c.generated.h"  // IWYU pragma: keep

/// Whether "wp" has drawn state that can be read: it is in the current tab page
/// and was drawn at least once.
static bool sm_win_readable(win_T *wp)
{
  ScreenGrid *g = wp->w_grid.target;
  return win_valid(wp) && wp->w_lines_valid > 0 && g != NULL && g->chars != NULL;
}

/// Whether the drawn state of "wp" matches the buffer and options (no redraw pending).
static bool sm_win_valid(win_T *wp)
{
  return sm_win_readable(wp) && wp->w_redr_type == 0;
}

/// Pointers to the cells of window row "row" (inner area, w_view_width cells).
static bool sm_row_cells(win_T *wp, int row, colnr_T **vcols, schar_T **chars)
{
  int r = row;
  int c = 0;
  if (wp->w_grid.target == NULL) {
    return false;
  }
  ScreenGrid *g = grid_adjust(&wp->w_grid, &r, &c);
  if (g == NULL || g->chars == NULL || r < 0 || r >= g->rows || c < 0
      || c + wp->w_view_width > g->cols) {
    return false;
  }
  size_t off = g->line_offset[r] + (size_t)c;
  *vcols = g->vcols + off;
  if (chars) {
    *chars = g->chars + off;
  }
  return true;
}

/// Screen column of the "i"th cell in draw order ('rightleft' draws right to left).
static inline int sm_col(win_T *wp, int i)
{
  return wp->w_p_rl ? wp->w_view_width - 1 - i : i;
}

/// Fill in filler/text row numbers of an entry starting at window row "row".
static void sm_entry_rows(win_T *wp, int idx, int row, SmEntry *e)
{
  const wline_T *wl = &wp->w_lines[idx];
  linenr_T lnum = wl->wl_lnum;
  int nvirt = decor_virt_lines(wp, lnum - 1, lnum, NULL, NULL, true);
  int nfill = lnum == wp->w_topline ? wp->w_topfill : win_get_fill(wp, lnum);
  nvirt = MIN(nvirt, nfill);
  e->wl = wl;
  e->row = row;
  e->nfill = MIN(nfill, MAX(wl->wl_size - 1, 0));
  e->nvirt = MIN(nvirt, e->nfill);
  e->text_row = row + e->nfill;
  e->end_row = MIN(row + wl->wl_size, wp->w_view_height);
}

/// Find the w_lines[] entry containing "lnum".
///
/// @return false when "lnum" is not inside the drawn part of the window.
static bool sm_find_entry(win_T *wp, linenr_T lnum, SmEntry *e, bool *entry_valid)
{
  int row = 0;
  for (int idx = 0; idx < wp->w_lines_valid && row < wp->w_view_height; idx++) {
    const wline_T *wl = &wp->w_lines[idx];
    if (wl->wl_lnum <= lnum && lnum <= wl->wl_lastlnum) {
      *entry_valid = wl->wl_valid;
      sm_entry_rows(wp, idx, row, e);
      return true;
    }
    row += wl->wl_size;
  }
  return false;
}

/// Virtual column range of the character at byte "col" of "lnum", like getvcol(),
/// plus the width of inline virtual text drawn before it.
///
/// @param[out] start  first vcol (after 'showbreak'/'breakindent', incl. inline virt text)
/// @param[out] end    last vcol
/// @param[out] pre    vcols of inline virtual text at the start of the range
/// @param[out] chr    the character, NUL at end of line
static void sm_getvcol(win_T *wp, SmLineCache *lc, linenr_T lnum, colnr_T col, colnr_T *start,
                       colnr_T *end, int *pre, int32_t *chr)
{
  char *line = ml_get_buf(wp->w_buffer, lnum);
  if (lc->lnum != lnum || lc->line != line || col < lc->ci.ptr - line) {
    lc->lnum = lnum;
    lc->line = line;
    lc->cstype = init_charsize_arg(&lc->csarg, wp, lnum, line);
    lc->csarg.max_head_vcol = -1;
    lc->ci = utf_ptr2StrCharInfo(line);
    lc->vcol = 0;
    lc->have_cs = false;
  }

  while (true) {
    if (!lc->have_cs) {
      lc->pre = 0;
      if (lc->cstype == kCharsizeFast) {
        lc->cs = *lc->ci.ptr == NUL
                 ? (CharSize){ .width = 1 }
                 : charsize_fast(&lc->csarg, lc->ci.ptr, lc->vcol, lc->ci.chr.value);
      } else {
        lc->cs = charsize_regular(&lc->csarg, lc->ci.ptr, lc->vcol, lc->ci.chr.value);
        lc->pre = lc->csarg.cur_text_width_left + lc->csarg.cur_text_width_right;
        if (*lc->ci.ptr == NUL) {
          lc->cs.width = 1 + lc->pre;
        }
      }
      lc->have_cs = true;
    }
    if (*lc->ci.ptr == NUL) {
      break;
    }
    StrCharInfo next = utfc_next(lc->ci);
    if (next.ptr - line > col) {
      break;
    }
    lc->ci = next;
    lc->vcol += lc->cs.width;
    lc->have_cs = false;
  }
  *start = lc->vcol + lc->cs.head;
  *end = lc->vcol + lc->cs.width - 1;
  *pre = MIN(lc->pre, *end - *start);
  *chr = *lc->ci.ptr == NUL ? NUL : lc->ci.chr.value;
}

/// Whether a drawn cell can be compared with the buffer character "c":
/// false for characters that are drawn differently on purpose (tabs, control
/// characters, 'list' characters for spaces, Arabic shaping).
static bool sm_char_checkable(int32_t c)
{
  return c > ' ' && c != 0xa0 && c != 0x202f && vim_isprintc(c)
         && !(p_arshape && ((c >= 0x600 && c <= 0x8ff) || (c >= 0xfb50 && c <= 0xfeff)));
}

/// Whether window row "row", draw-order cell "i" may be overwritten by the
/// 'smoothscroll' "<<<" marker.
static bool sm_skipcol_overlay(win_T *wp, int row, int i)
{
  int textoff = win_col_off(wp);
  return row == 0 && wp->w_skipcol > 0 && i >= textoff && i < textoff + 3;
}

/// Look up one buffer position.
static Dict sm_lookup(win_T *wp, SmLineCache *lc, bool readable, bool win_ok, linenr_T lnum,
                      colnr_T col, bool want_abs, Arena *arena)
{
  Dict d = arena_dict(arena, 9);
  bool valid = win_ok;
  bool visible = false;
  const char *kind = "offscreen";
  int nsegs = 0;
  int segs[SM_MAX_SEGS][3];
  int pre_cells = 0;
  bool overlay = false;

  colnr_T vstart = 0;
  colnr_T vend = 0;
  int pre = 0;
  int32_t chr = NUL;
  sm_getvcol(wp, lc, lnum, col, &vstart, &vend, &pre, &chr);
  colnr_T cstart = vstart + pre;  // the character's own cells

  if (!lc->entry_found || lc->entry.wl == NULL || lc->entry.wl->wl_lnum > lnum
      || lnum > lc->entry.wl->wl_lastlnum) {
    lc->entry_valid = true;
    lc->entry.wl = NULL;
    lc->entry_found = readable && sm_find_entry(wp, lnum, &lc->entry, &lc->entry_valid);
  }
  SmEntry e = lc->entry;
  bool entry_valid = lc->entry_valid;
  if (lc->entry_found) {
    valid = valid && entry_valid;
    if (e.wl->wl_folded) {
      kind = "fold";
      int frow = e.row + e.wl->wl_size - 1;
      if (frow < wp->w_view_height) {
        visible = true;
        segs[0][0] = frow;
        segs[0][1] = win_col_off(wp);
        segs[0][2] = wp->w_view_width - 1;
        nsegs = 1;
      }
    } else if (lnum != e.wl->wl_lnum) {
      kind = "hidden_line";
    } else {
      // Scan the text rows of the line in draw order.  The first cell whose
      // vcol is in range is the character; following cells belong to it while
      // their vcols keep increasing (trailing fill repeats the last vcol).
      int last_v = -1;
      // fallback for a position without a cell: nearest drawn cell before it
      int before_row = -1;
      int before_i = -1;
      colnr_T before_v = -1;
      bool after_found = false;
      int after_row = -1;
      int after_i = -1;
      bool done = false;
      for (int row = e.text_row; row < e.end_row && !done; row++) {
        colnr_T *vcols;
        if (!sm_row_cells(wp, row, &vcols, NULL)) {
          break;
        }
        int seg_start = -1;
        int seg_end = -1;
        for (int i = 0; i < wp->w_view_width; i++) {
          colnr_T v = vcols[sm_col(wp, i)];
          if (seg_start >= 0) {
            if (v >= cstart && v <= vend && v > last_v) {
              seg_end = i;
              last_v = v;
              continue;
            }
            break;
          }
          if (v < 0) {
            continue;
          }
          if (v >= cstart && v <= vend && v > last_v) {
            if (nsegs > 0 && i > 0) {
              // a continuation must start the row's text
              bool text_before = false;
              for (int j = 0; j < i; j++) {
                colnr_T vj = vcols[sm_col(wp, j)];
                if (vj >= cstart) {
                  text_before = true;
                  break;
                }
              }
              if (text_before) {
                break;
              }
            }
            seg_start = seg_end = i;
            last_v = v;
          } else if (v < cstart && v > before_v) {
            before_v = v;
            before_row = row;
            before_i = i;
          } else if (v > vend && !after_found) {
            after_found = true;
            after_row = row;
            after_i = i;
          }
        }
        if (seg_start >= 0) {
          if (nsegs < SM_MAX_SEGS) {
            segs[nsegs][0] = row;
            segs[nsegs][1] = seg_start;
            segs[nsegs][2] = seg_end;
            nsegs++;
          }
          if (last_v >= vend) {
            done = true;
          }
        } else if (nsegs > 0) {
          done = true;
        }
      }

      if (nsegs > 0) {
        visible = true;
        kind = chr == NUL ? "eol" : "text";
        // Count inline virtual text cells right before the character.
        if (pre > 0) {
          colnr_T *vcols;
          if (sm_row_cells(wp, segs[0][0], &vcols, NULL)) {
            colnr_T prev = cstart;
            for (int i = segs[0][1] - 1; i >= 0; i--) {
              colnr_T v = vcols[sm_col(wp, i)];
              if (v < vstart || v >= prev) {
                break;
              }
              prev = v;
              pre_cells++;
            }
          }
        }
        // A cell that does not show the buffer character is a conceal
        // replacement (or blank cells standing in for concealed text).
        int row = segs[0][0];
        int i = segs[0][1];
        colnr_T *vcols;
        schar_T *chars;
        if (sm_skipcol_overlay(wp, row, i)) {
          overlay = true;
        } else if (chr != NUL && sm_char_checkable(chr)
                   && sm_row_cells(wp, row, &vcols, &chars)
                   && schar_get_first_codepoint(chars[sm_col(wp, i)]) != chr) {
          kind = "concealed";
        }
      } else if (after_found
                 && !(!wp->w_p_wrap && vend < wp->w_leftcol)
                 && !(lnum == wp->w_topline && vend < wp->w_skipcol)) {
        // No cell, but text after it is drawn: concealed (left of 'leftcol'
        // or scrolled away by 'smoothscroll' is "offscreen").  Use the nearest drawn cell before it, or the
        // first cell after it when nothing is drawn before.
        visible = true;
        kind = "concealed";
        int row = before_row >= 0 ? before_row : after_row;
        int i = before_row >= 0 ? before_i : after_i;
        segs[0][0] = row;
        segs[0][1] = segs[0][2] = i;
        nsegs = 1;
      }
    }
  }

  PUT_C(d, "valid", BOOLEAN_OBJ(valid));
  PUT_C(d, "visible", BOOLEAN_OBJ(visible));
  PUT_C(d, "kind", CSTR_AS_OBJ(kind));
  Array sa = arena_array(arena, (size_t)nsegs);
  for (int s = 0; s < nsegs; s++) {
    // convert draw order to screen columns
    int c0 = sm_col(wp, segs[s][1]);
    int c1 = sm_col(wp, segs[s][2]);
    Array seg = arena_array(arena, 3);
    ADD_C(seg, INTEGER_OBJ(segs[s][0]));
    ADD_C(seg, INTEGER_OBJ(MIN(c0, c1)));
    ADD_C(seg, INTEGER_OBJ(MAX(c0, c1)));
    ADD_C(sa, ARRAY_OBJ(seg));
    segs[s][1] = MIN(c0, c1);
  }
  PUT_C(d, "segs", ARRAY_OBJ(sa));
  PUT_C(d, "pre", INTEGER_OBJ(pre_cells));
  PUT_C(d, "vcol0", INTEGER_OBJ(cstart));
  PUT_C(d, "vcol1", INTEGER_OBJ(vend));
  if (overlay) {
    PUT_C(d, "skipcol_overlay", BOOLEAN_OBJ(true));
  }
  if (want_abs && nsegs > 0) {
    Array abs = arena_array(arena, 2);
    ADD_C(abs, INTEGER_OBJ(wp->w_winrow + wp->w_winrow_off + segs[0][0]));
    ADD_C(abs, INTEGER_OBJ(wp->w_wincol + wp->w_wincol_off + segs[0][1]));
    PUT_C(d, "abs", ARRAY_OBJ(abs));
  }
  return d;
}

/// EXPERIMENTAL: this API may change in the future.
///
/// Gets where buffer positions were last drawn in a window, from the drawn
/// screen state (works with conceal, 'linebreak', inline virtual text, ...).
/// Does not redraw: check "valid" in the result.
///
/// @param win  |window-ID|, or 0 for current window
/// @param positions  List of `[row, col]` positions, 0-based line and byte column.
///                   A column past the end of the line means the end of line.
/// @param opts Optional parameters:
///           - abs: (boolean, default true) include "abs".
/// @return List with one dict per position:
///         - valid: false when the window has a pending redraw; then the
///           result describes what is currently on the screen.
///         - visible: a cell was found.
///         - kind: "text", "concealed" (no own cell, or a conceal replacement;
///           "segs" is the nearest drawn cell), "eol", "fold" (closed fold,
///           "segs" is the text area of the fold line), "offscreen",
///           "hidden_line" ('conceal_lines').
///         - segs: list of `[row, startcol, endcol]` (0-based, inclusive,
///           relative to the inner window area, which includes the number
///           column), one per screen row the character occupies.
///         - pre: inline virtual text cells right before the first segment.
///         - vcol0, vcol1: virtual columns of the character (0-based, inclusive).
///         - abs: `[row, col]` screen position of the first cell of "segs".
///         - skipcol_overlay: true when the cell may show the 'smoothscroll'
///           "<<<" marker.
Array nvim__win_screen_cells(Window win, Array positions, Dict(win_screen_cells) *opts,
                             Arena *arena, Error *err)
{
  Array rv = ARRAY_DICT_INIT;
  win_T *wp = find_window_by_handle(win, err);
  if (!wp) {
    return rv;
  }
  buf_T *buf = wp->w_buffer;
  bool want_abs = HAS_KEY(opts, win_screen_cells, abs) ? opts->abs : true;

  for (size_t i = 0; i < positions.size; i++) {
    Object p = positions.items[i];
    VALIDATE_EXP(p.type == kObjectTypeArray && p.data.array.size == 2
                 && p.data.array.items[0].type == kObjectTypeInteger
                 && p.data.array.items[1].type == kObjectTypeInteger,
                 "positions", "[row, col] Integer pair", NULL, {
      return rv;
    });
    Integer row = p.data.array.items[0].data.integer;
    Integer col = p.data.array.items[1].data.integer;
    VALIDATE_RANGE(row >= 0 && row < buf->b_ml.ml_line_count, "row", {
      return rv;
    });
    VALIDATE_RANGE(col >= 0, "col", {
      return rv;
    });
  }

  bool readable = sm_win_readable(wp);
  bool win_ok = sm_win_valid(wp);
  SmLineCache lc = { .lnum = 0 };
  rv = arena_array(arena, positions.size);
  for (size_t i = 0; i < positions.size; i++) {
    Array p = positions.items[i].data.array;
    linenr_T lnum = (linenr_T)p.items[0].data.integer + 1;
    colnr_T col = (colnr_T)MIN(p.items[1].data.integer, MAXCOL);
    ADD_C(rv, DICT_OBJ(sm_lookup(wp, &lc, readable, win_ok, lnum, col, want_abs, arena)));
  }
  return rv;
}

static Dict sm_row_dict(win_T *wp, int row, linenr_T lnum, const char *kind, bool want_cells,
                        Arena *arena)
{
  Dict d = arena_dict(arena, 5);
  colnr_T first = -1;
  colnr_T last = -1;
  colnr_T *vcols = NULL;
  bool have = sm_row_cells(wp, row, &vcols, NULL);
  if (have && (strcmp(kind, "text") == 0 || strcmp(kind, "wrap") == 0)) {
    for (int i = 0; i < wp->w_view_width; i++) {
      colnr_T v = vcols[i];
      if (v >= 0) {
        first = first < 0 ? v : MIN(first, v);
        last = MAX(last, v);
      }
    }
  }
  PUT_C(d, "lnum", INTEGER_OBJ(lnum > 0 ? lnum - 1 : -1));
  PUT_C(d, "kind", CSTR_AS_OBJ(kind));
  PUT_C(d, "first_vcol", INTEGER_OBJ(first));
  PUT_C(d, "last_vcol", INTEGER_OBJ(last));
  if (want_cells) {
    Array a = arena_array(arena, have ? (size_t)wp->w_view_width : 0);
    for (int i = 0; have && i < wp->w_view_width; i++) {
      ADD_C(a, INTEGER_OBJ(vcols[i]));
    }
    PUT_C(d, "vcols", ARRAY_OBJ(a));
  }
  return d;
}

/// EXPERIMENTAL: this API may change in the future.
///
/// Gets the drawn layout of a window: geometry and what each window row shows.
/// Does not redraw: check "valid" in the result.
///
/// @param win  |window-ID|, or 0 for current window
/// @param opts Optional parameters:
///           - cells: (boolean, default false) add "vcols" to each row.
/// @return Dict with keys "valid", "win_row", "win_col", "inner_row",
///         "inner_col", "width", "height", "textoff", "topline" (0-based),
///         "skipcol", "leftcol", "wrap" and "rows": one dict per window row with
///         - lnum: 0-based buffer line, -1 for none.
///         - kind: "text", "wrap", "fold", "fill" (diff filler), "virt"
///           (virt_lines) or "eob".
///         - first_vcol, last_vcol: smallest and largest virtual column drawn in
///           the row, -1 if none.
///         - vcols: (with "cells") virtual column per cell, -1 for no text.
Dict nvim__win_screen_map(Window win, Dict(win_screen_map) *opts, Arena *arena, Error *err)
{
  Dict rv = ARRAY_DICT_INIT;
  win_T *wp = find_window_by_handle(win, err);
  if (!wp) {
    return rv;
  }
  bool want_cells = HAS_KEY(opts, win_screen_map, cells) && opts->cells;
  bool readable = sm_win_readable(wp);
  bool valid = sm_win_valid(wp);

  rv = arena_dict(arena, 13);
  int height = MAX(wp->w_view_height, 0);
  Array rows = arena_array(arena, (size_t)height);

  int row = 0;
  if (readable) {
    for (int idx = 0; idx < wp->w_lines_valid && row < height; idx++) {
      SmEntry e;
      sm_entry_rows(wp, idx, row, &e);
      valid = valid && e.wl->wl_valid;
      for (int r = e.row; r < e.end_row; r++) {
        const char *kind;
        linenr_T lnum = e.wl->wl_lnum;
        if (r < e.text_row) {
          kind = r - e.row < e.nvirt ? "virt" : "fill";
        } else if (e.wl->wl_folded) {
          kind = "fold";
        } else {
          kind = r == e.text_row ? "text" : "wrap";
        }
        ADD_C(rows, DICT_OBJ(sm_row_dict(wp, r, lnum, kind, want_cells, arena)));
      }
      row += e.wl->wl_size;
    }
  }
  int eob_start = MAX(row, height - wp->w_empty_rows);
  for (int r = MIN(row, height); r < height; r++) {
    bool eob = r >= eob_start || !readable;
    linenr_T lnum = eob ? 0 : wp->w_buffer->b_ml.ml_line_count;
    ADD_C(rows, DICT_OBJ(sm_row_dict(wp, r, lnum, eob ? "eob" : "virt", want_cells, arena)));
  }

  PUT_C(rv, "valid", BOOLEAN_OBJ(valid));
  PUT_C(rv, "win_row", INTEGER_OBJ(wp->w_winrow));
  PUT_C(rv, "win_col", INTEGER_OBJ(wp->w_wincol));
  PUT_C(rv, "inner_row", INTEGER_OBJ(wp->w_winrow + wp->w_winrow_off));
  PUT_C(rv, "inner_col", INTEGER_OBJ(wp->w_wincol + wp->w_wincol_off));
  PUT_C(rv, "width", INTEGER_OBJ(wp->w_view_width));
  PUT_C(rv, "height", INTEGER_OBJ(wp->w_view_height));
  PUT_C(rv, "textoff", INTEGER_OBJ(win_col_off(wp)));
  PUT_C(rv, "topline", INTEGER_OBJ(wp->w_topline - 1));
  PUT_C(rv, "skipcol", INTEGER_OBJ(wp->w_skipcol));
  PUT_C(rv, "leftcol", INTEGER_OBJ(wp->w_leftcol));
  PUT_C(rv, "wrap", BOOLEAN_OBJ(wp->w_p_wrap));
  PUT_C(rv, "rows", ARRAY_OBJ(rows));
  return rv;
}
