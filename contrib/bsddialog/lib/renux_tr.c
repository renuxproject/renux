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
 * Renux: the dialogs in the user's language.  When RENUX_LANG_TABLE names a
 * table, every text a dialog shows (its text, title, buttons, the names and
 * descriptions of menu items, the labels of forms and gauges, the months
 * of the calendar) is looked up there as the dialog draws it: the programs
 * that use the library (bsdinstall's partedit and distextract, tzsetup)
 * show their dialogs translated, and read back what they always did.
 *
 * The table has a line per text, the English text and its translation
 * separated by a tab; \n and \t stand for a newline and a tab, and lines
 * that start with # are comments.  A text with %s matches any text that
 * has something in place of each %s, which goes in place of the %s of the
 * translation, in order: "Initializing %s" matches "Initializing vtbd0p2".
 */

#include <curses.h>
#include <locale.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wctype.h>

#include "bsddialog.h"
#include "lib_util.h"

#define RENUX_TR_MAXARGS 8

struct renux_tr_entry {
	char *from;
	char *to;
	bool pattern;	/* from has %s */
};

static struct renux_tr_entry *entries;
static size_t nentries;
static bool loaded;

/* \n and \t in place, as the table writes them. */
static void
unescape(char *s)
{
	char *w;

	for (w = s; *s != '\0'; s++) {
		if (s[0] == '\\' && s[1] == 'n') {
			*w++ = '\n';
			s++;
		} else if (s[0] == '\\' && s[1] == 't') {
			*w++ = '\t';
			s++;
		} else if (s[0] == '\\' && s[1] == '\\') {
			*w++ = '\\';
			s++;
		} else
			*w++ = *s;
	}
	*w = '\0';
}

static void
load(void)
{
	struct renux_tr_entry *e;
	const char *path;
	char *line, *tab;
	size_t cap, len;
	FILE *fp;

	loaded = true;
	if ((path = getenv("RENUX_LANG_TABLE")) == NULL)
		return;
	if ((fp = fopen(path, "r")) == NULL)
		return;
	line = NULL;
	cap = 0;
	while (getline(&line, &cap, fp) > 0) {
		len = strlen(line);
		if (len > 0 && line[len - 1] == '\n')
			line[--len] = '\0';
		if (line[0] == '#' || (tab = strchr(line, '\t')) == NULL)
			continue;
		*tab = '\0';
		e = realloc(entries, (nentries + 1) * sizeof(*entries));
		if (e == NULL)
			break;
		entries = e;
		e = &entries[nentries];
		if ((e->from = strdup(line)) == NULL ||
		    (e->to = strdup(tab + 1)) == NULL)
			break;
		unescape(e->from);
		unescape(e->to);
		e->pattern = strstr(e->from, "%s") != NULL;
		nentries++;
	}
	free(line);
	fclose(fp);
}

/*
 * Whether text matches pattern, with the text in place of each %s in
 * args (pointers into text) and lens.
 */
static bool
match(const char *pattern, const char *text, const char **args, size_t *lens,
    int *nargs)
{
	const char *p, *t, *next, *found;
	size_t litlen;

	*nargs = 0;
	p = pattern;
	t = text;
	/* The literal before the first %s. */
	next = strstr(p, "%s");
	litlen = next - p;
	if (strncmp(t, p, litlen) != 0)
		return (false);
	t += litlen;
	p = next + 2;
	while (*nargs < RENUX_TR_MAXARGS) {
		next = strstr(p, "%s");
		litlen = next != NULL ? (size_t)(next - p) : strlen(p);
		if (next == NULL) {
			/* The last literal ends the text. */
			if (strlen(t) < litlen ||
			    strcmp(t + strlen(t) - litlen, p) != 0)
				return (false);
			args[*nargs] = t;
			lens[*nargs] = strlen(t) - litlen;
			(*nargs)++;
			return (true);
		}
		if (litlen == 0)
			return (false);	/* %s%s: ambiguous */
		{
			char lit[litlen + 1];

			memcpy(lit, p, litlen);
			lit[litlen] = '\0';
			if ((found = strstr(t, lit)) == NULL)
				return (false);
		}
		args[*nargs] = t;
		lens[*nargs] = found - t;
		(*nargs)++;
		t = found + litlen;
		p = next + 2;
	}
	return (false);
}

/* The translation of to, with args in place of its %s. */
static const char *
fill(const char *to, const char **args, const size_t *lens, int nargs)
{
	const char *s;
	char *out, *w;
	size_t size;
	int i;

	size = strlen(to) + 1;
	for (i = 0; i < nargs; i++)
		size += lens[i];
	if ((out = malloc(size)) == NULL)
		return (to);
	w = out;
	i = 0;
	for (s = to; *s != '\0'; s++) {
		if (s[0] == '%' && s[1] == 's' && i < nargs) {
			memcpy(w, args[i], lens[i]);
			w += lens[i];
			i++;
			s++;
		} else
			*w++ = *s;
	}
	*w = '\0';
	return (out);
}

void
renux_tr_init(void)
{
	/* UTF-8, for the accents of the translations. */
	if (getenv("RENUX_LANG_TABLE") != NULL)
		setlocale(LC_ALL, "");
}

const char *
renux_tr(const char *text)
{
	const char *args[RENUX_TR_MAXARGS];
	size_t lens[RENUX_TR_MAXARGS];
	size_t i;
	int nargs;

	if (text == NULL || text[0] == '\0')
		return (text);
	if (!loaded)
		load();
	for (i = 0; i < nentries; i++) {
		if (!entries[i].pattern && strcmp(entries[i].from, text) == 0)
			return (entries[i].to);
	}
	for (i = 0; i < nentries; i++) {
		if (entries[i].pattern &&
		    match(entries[i].from, text, args, lens, &nargs))
			return (fill(entries[i].to, args, lens, nargs));
	}
	return (text);
}

/*
 * A text of a fixed width with spaces around it (the states of a gauge):
 * translated without its spaces, then centered in width again.
 */
const char *
renux_tr_centered(const char *text, int width)
{
	static char buf[64];
	const char *tr;
	char word[64];
	size_t start, len;
	int pad;

	start = strspn(text, " ");
	len = strlen(text + start);
	while (len > 0 && text[start + len - 1] == ' ')
		len--;
	if (len >= sizeof(word))
		return (text);
	memcpy(word, text + start, len);
	word[len] = '\0';
	tr = renux_tr(word);
	if (tr == word)
		return (text);
	pad = (width - (int)strcols(tr)) / 2;
	if (pad < 0)
		pad = 0;
	snprintf(buf, sizeof(buf), "%*s%s%*s", pad, "", tr,
	    width - pad - (int)strcols(tr) > 0 ?
	    width - pad - (int)strcols(tr) : 0, "");
	return (buf);
}
