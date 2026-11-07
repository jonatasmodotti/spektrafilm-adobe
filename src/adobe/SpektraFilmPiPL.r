#include "AE_EffectVers.h"
#ifndef AE_OS_WIN
#include "AE_General.r"
#endif

resource 'PiPL' (16000) {
  {
    Kind { AEEffect },
    Name { "spektrafilm" },
    Category { "spektrafilm" },
#ifdef AE_OS_WIN
    CodeWin64X86 { "EffectMain" },
#else
    CodeMacIntel64 { "EffectMain" },
    CodeMacARM64 { "EffectMain" },
#endif
    AE_PiPL_Version { 2, 0 },
    AE_Effect_Spec_Version { PF_PLUG_IN_VERSION, PF_PLUG_IN_SUBVERS },
    AE_Effect_Version { SPEKTRAFILM_PF_VERSION },  /* defined by CMake */
    AE_Effect_Info_Flags { 0 },
    AE_Effect_Global_OutFlags { 0x02008004 },
#ifdef AE_OS_WIN
    AE_Effect_Global_OutFlags_2 { 0x08001401 },
#else
    AE_Effect_Global_OutFlags_2 { 0x0a001401 },
#endif
    AE_Effect_Match_Name { "org.spektrafilm.adobe" },
    AE_Reserved_Info { 8 },
    AE_Effect_Support_URL { "https://github.com/jonatasmodotti/spektrafilm-adobe" }
  }
};
