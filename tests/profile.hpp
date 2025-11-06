#pragma once

#ifdef FP_ENABLE_PROFILING
	#include <tracy/Tracy.hpp>

	#define FP_ZONE_SCOPED ZoneScoped
	#define FP_ZONE_SCOPED_NAMED(name) ZoneScopedN(name)
	#define FP_FRAME_MARK FrameMark

	#ifdef FP_AGGRESSIVE_PROFILING
		#define FP_ZONE_SCOPED_AGGRO ZoneScoped
		#define FP_ZONE_SCOPED_NAMED_AGGRO(name) ZoneScopedN(name)
	#else
		#define FP_ZONE_SCOPED_AGGRO ((void)0)
		#define FP_ZONE_SCOPED_NAMED_AGGRO(name) ((void)0)
	#endif // FP_AGGRESSIVE_PROFILING
#else // FP_NO_PROFILING
	#define FP_ZONE_SCOPED ((void)0)
	#define FP_ZONE_SCOPED_NAMED(name) ((void)0)
	#define FP_ZONE_SCOPED_AGGRO ((void)0)
	#define FP_ZONE_SCOPED_NAMED_AGGRO(name) ((void)0)
	#define FP_FRAME_MARK ((void)0)
#endif
