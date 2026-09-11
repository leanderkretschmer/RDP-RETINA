/*
 * rdp-retina – Präfix-Header für alle Übersetzungseinheiten der Mac-App
 *
 * WinPR (wtypes.h) und CoreFoundation (CFPlugInCOM.h, steckt in jedem Foundation-Import)
 * definieren beide REFIID – als IID* bzw. CFUUIDBytes. Alle übrigen doppelten Typen sind
 * gleich. In Objective-C-Dateien wird wtypes.h deshalb vor allem anderen eingebunden und
 * sein REFIID umbenannt; gleich danach kommt Foundation, damit spätere WinPR-Header, die
 * REFIID nur in Prototypen nennen, den Typ vorfinden.
 *
 * Die C-Dateien des Kerns binden CoreFoundation nie ein und bleiben unberührt.
 */
#ifndef RR_PREFIX_H
#define RR_PREFIX_H

#if defined(__OBJC__)
#define REFIID WINPR_REFIID
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmacro-redefined"
#include <winpr/wtypes.h>
#include <winpr/error.h>
#pragma clang diagnostic pop
#undef REFIID
#import <Foundation/Foundation.h>
#endif

#endif /* RR_PREFIX_H */
