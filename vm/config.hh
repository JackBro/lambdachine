#ifndef _LAMBDACHINE_CONFIG_H
#define _LAMBDACHINE_CONFIG_H

#include "autoconfig.h"

#ifndef LC_HAS_JIT
# define LC_HAS_JIT      1
#endif

#ifndef LC_HAS_ASM_BACKEND
# define LC_HAS_ASM_BACKEND 1
#endif

/* #define LC_SELF_CHECK_MODE */

/* #undef NDEBUG */
/* #define DEBUG */

#define LC_USE_VALGRIND 1

#ifndef LC_DEBUG_LEVEL
# ifdef NDEBUG
#  define LC_DEBUG_LEVEL  0
# else
#  define LC_DEBUG_LEVEL  1
# endif
#endif

#define LC_JIT   1

#define MAX_HEAP_ENTRIES      300

#define HOT_SIDE_EXIT_THRESHOLD  7

#define DEBUG_MEMORY_MANAGER  0x00000001L
#define DEBUG_LOADER          0x00000002L
#define DEBUG_INTERPRETER     0x00000004L
#define DEBUG_TRACE_RECORDER  0x00000008L
#define DEBUG_ASSEMBLER       0x00000010L
#define DEBUG_TRACE_ENTEREXIT 0x00000020L
#define DEBUG_FALSE_LOOP_FILT 0x00000040L

// #define DEBUG_COMPONENTS     0xffffffffL
// #define DEBUG_COMPONENTS    (DEBUG_MEMORY_MANAGER|DEBUG_INTERPRETER)
// #define DEBUG_COMPONENTS    (DEBUG_ASSEMBLER|DEBUG_TRACE_ENTEREXIT)
#define DEBUG_COMPONENTS    (DEBUG_ASSEMBLER)
// #define DEBUG_COMPONENTS    (DEBUG_TRACE_RECORDER|DEBUG_INTERPRETER)

#endif
