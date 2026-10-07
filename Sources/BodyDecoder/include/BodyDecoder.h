#include <stddef.h>
// Caller frees the returned UTF-8 string. NULL means unsupported or malformed.
char *ma_decode_body(const void *bytes, size_t count);
