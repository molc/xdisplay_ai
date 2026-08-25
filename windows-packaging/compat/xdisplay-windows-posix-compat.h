#pragma once

#if defined(_WIN32)
#include <io.h>

#ifndef fsync
#define fsync _commit
#endif
#endif
