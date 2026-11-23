/* E060 sensitivity: d879745 src/abi/object.c の本文、関数名だけlegacyへ。 */
static int legacy_rejected_at(const char *log, size_t n, char *out, size_t cap)
{
	int found = 0;
	for (size_t i = 0; i < n;) {
		size_t e = i;
		while (e < n && log[e] != '\n')
			e++;
		const char *s = log + i, *end = log + e;
		while (s < end && isspace((unsigned char)*s))
			s++;
		if (end - s > 2 && s[0] == ';' && s[1] == ' ') {
			const char *f = s + 2, *c = f;
			while (c < end && *c != ':' && *c != '@' && !isspace((unsigned char)*c))
				c++;
			const char *d = c + 1, *de = d;
			while (de < end && isdigit((unsigned char)*de))
				de++;
			const char *t = de;
			if (t < end && t[0] == ' ' && t + 1 < end && t[1] == '@') {
				t += 2;
				while (t < end && !isspace((unsigned char)*t))
					t++;
			}
			while (t < end && isspace((unsigned char)*t))
				t++;
			if (c > f && c < end && *c == ':' && de > d && t == end) {
				snprintf(out, cap, "%.*s:%.*s", (int)(c - f), f, (int)(de - d), d);
				found = 1;
			}
		}
		i = e + 1;
	}
	return found;
}
