//
//  UMMPFastDicom.h
//  IsiX/Horos port: fast reading of single header tags.
//
//  The plugin reads timing tags (Acquisition Time, Trigger Time, ...) from every image of a
//  4D series when the panel opens. Doing that with DCMObject parses the whole header of each
//  file, which took many seconds for a typical DSC series (e.g. 50 time points x 30 slices).
//  UMMPFastDicomString() reads only the start of the file and walks the data elements until it
//  reaches the requested tag. Anything unusual (big endian, deflate, undefined lengths before
//  the tag, a truncated header) makes it report failure, and the caller falls back to DCMObject.
//
//  Copyright (c) 2026 Artem Sobolev. BSD 3-Clause licence (see LICENSE).
//

#ifndef UMMPFastDicom_h
#define UMMPFastDicom_h

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

typedef enum { UMMPFastNotFound = 0, UMMPFastFound = 1, UMMPFastFailed = -1 } UMMPFastResult;

static inline uint16_t UMMPRead16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t UMMPRead32(const unsigned char *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

static inline int UMMPIsLongVR(const char *vr)
{
    static const char *longVRs[] = {"OB","OW","OF","SQ","UT","UN","OD","OL","OV","UC","UR","SV","UV"};
    for (size_t i = 0; i < sizeof(longVRs) / sizeof(longVRs[0]); i++)
        if (vr[0] == longVRs[i][0] && vr[1] == longVRs[i][1]) return 1;
    return 0;
}

static inline int UMMPIsTextVR(const char *vr)
{
    static const char *textVRs[] = {"AE","AS","CS","DA","DS","DT","IS","LO","LT","PN","SH","ST","TM","UI","UT","UC","UR"};
    for (size_t i = 0; i < sizeof(textVRs) / sizeof(textVRs[0]); i++)
        if (vr[0] == textVRs[i][0] && vr[1] == textVRs[i][1]) return 1;
    return 0;
}

// First value of a text element, without padding (like [[DCMAttribute value] description]).
static inline NSString *UMMPFastTextValue(const unsigned char *v, uint32_t len)
{
    uint32_t end = 0;
    while (end < len && v[end] != '\\') end++;                  // first of several values
    uint32_t start = 0;
    while (start < end && (v[start] == ' ' || v[start] == 0)) start++;
    while (end > start && (v[end - 1] == ' ' || v[end - 1] == 0)) end--;
    for (uint32_t i = start; i < end; i++) if (v[i] < 0x20 || v[i] > 0x7e) return nil;   // not plain text
    return [[[NSString alloc] initWithBytes:v + start length:end - start encoding:NSASCIIStringEncoding] autorelease];
}

static inline UMMPFastResult UMMPFastParse(const unsigned char *buf, size_t size, uint32_t target, NSString **out, BOOL *needMore)
{
    size_t pos = 0;
    int explicitVR = 1;
    *needMore = NO;

    if (size >= 132 && memcmp(buf + 128, "DICM", 4) == 0) {
        pos = 132;
        char ts[65] = {0};
        while (pos + 8 <= size && UMMPRead16(buf + pos) == 0x0002) {      // file meta: explicit LE
            uint16_t el = UMMPRead16(buf + pos + 2);
            char vr[2] = {(char)buf[pos + 4], (char)buf[pos + 5]};
            uint32_t len; size_t hdr;
            if (UMMPIsLongVR(vr)) { if (pos + 12 > size) { *needMore = YES; return UMMPFastFailed; } len = UMMPRead32(buf + pos + 8); hdr = 12; }
            else { len = UMMPRead16(buf + pos + 6); hdr = 8; }
            if (len == 0xFFFFFFFF) return UMMPFastFailed;
            if (pos + hdr + len > size) { *needMore = YES; return UMMPFastFailed; }
            if (el == 0x0010 && len < sizeof(ts)) { memcpy(ts, buf + pos + hdr, len); }
            pos += hdr + len;
        }
        for (int i = (int)strlen(ts) - 1; i >= 0 && (ts[i] == 0 || ts[i] == ' '); i--) ts[i] = 0;
        if (strcmp(ts, "1.2.840.10008.1.2") == 0) explicitVR = 0;                  // implicit little endian
        else if (strcmp(ts, "1.2.840.10008.1.2.2") == 0) return UMMPFastFailed;   // big endian
        else if (strncmp(ts, "1.2.840.10008.1.2.1.99", 22) == 0) return UMMPFastFailed;  // deflate
    } else {
        // no preamble: guess from the first element
        if (size < 8) return UMMPFastFailed;
        explicitVR = (buf[4] >= 'A' && buf[4] <= 'Z' && buf[5] >= 'A' && buf[5] <= 'Z');
    }

    while (pos + 8 <= size) {
        uint16_t gr = UMMPRead16(buf + pos), el = UMMPRead16(buf + pos + 2);
        uint32_t key = ((uint32_t)gr << 16) | el;
        if (gr == 0xFFFE) return UMMPFastFailed;                 // item/delimiter at top level
        char vr[3] = {0, 0, 0};
        uint32_t len; size_t hdr;
        if (explicitVR) {
            vr[0] = (char)buf[pos + 4]; vr[1] = (char)buf[pos + 5];
            if (UMMPIsLongVR(vr)) { if (pos + 12 > size) { *needMore = YES; return UMMPFastFailed; } len = UMMPRead32(buf + pos + 8); hdr = 12; }
            else { len = UMMPRead16(buf + pos + 6); hdr = 8; }
        } else {
            len = UMMPRead32(buf + pos + 4); hdr = 8;
        }
        if (key > target) return UMMPFastNotFound;               // elements are in ascending order
        if (len == 0xFFFFFFFF) return UMMPFastFailed;            // undefined length before the tag
        if (pos + hdr + len > size) { *needMore = YES; return UMMPFastFailed; }
        if (key == target) {
            const unsigned char *v = buf + pos + hdr;
            if (!explicitVR || UMMPIsTextVR(vr)) {
                NSString *s = UMMPFastTextValue(v, len);
                if (!s) return UMMPFastFailed;
                *out = s; return UMMPFastFound;
            }
            if (vr[0] == 'U' && vr[1] == 'S' && len >= 2) { *out = [NSString stringWithFormat:@"%u", UMMPRead16(v)]; return UMMPFastFound; }
            if (vr[0] == 'S' && vr[1] == 'S' && len >= 2) { *out = [NSString stringWithFormat:@"%d", (int16_t)UMMPRead16(v)]; return UMMPFastFound; }
            if (vr[0] == 'U' && vr[1] == 'L' && len >= 4) { *out = [NSString stringWithFormat:@"%u", UMMPRead32(v)]; return UMMPFastFound; }
            if (vr[0] == 'S' && vr[1] == 'L' && len >= 4) { *out = [NSString stringWithFormat:@"%d", (int32_t)UMMPRead32(v)]; return UMMPFastFound; }
            if (vr[0] == 'F' && vr[1] == 'L' && len >= 4) { float f; memcpy(&f, v, 4); *out = [NSString stringWithFormat:@"%g", f]; return UMMPFastFound; }
            if (vr[0] == 'F' && vr[1] == 'D' && len >= 8) { double d; memcpy(&d, v, 8); *out = [NSString stringWithFormat:@"%.17g", d]; return UMMPFastFound; }
            return UMMPFastFailed;
        }
        pos += hdr + len;
    }
    *needMore = YES;
    return UMMPFastFailed;
}

// Value of tag (group,element) as text, or nil if the file does not contain it.
// *ok is NO when the file could not be read this way (the caller should fall back to DCMObject).
// Thread-safe.
static inline NSString *UMMPFastDicomString(NSString *path, uint16_t group, uint16_t element, BOOL *ok)
{
    *ok = NO;
    if (!path) return nil;
    FILE *f = fopen([path fileSystemRepresentation], "rb");
    if (!f) return nil;
    uint32_t target = ((uint32_t)group << 16) | element;
    size_t cap = 16384;
    NSString *result = nil;
    for (int attempt = 0; attempt < 3; attempt++) {
        unsigned char *buf = (unsigned char *)malloc(cap);
        if (!buf) break;
        fseek(f, 0, SEEK_SET);
        size_t n = fread(buf, 1, cap, f);
        BOOL needMore = NO;
        NSString *value = nil;
        UMMPFastResult r = UMMPFastParse(buf, n, target, &value, &needMore);
        free(buf);
        if (r != UMMPFastFailed) { *ok = YES; result = value; break; }
        if (!needMore || n < cap) break;          // genuine failure, or the whole file was read
        cap *= 8;                                  // 16 KB -> 128 KB -> 1 MB
    }
    fclose(f);
    return result;
}

// "gggg,eeee" -> group/element; NO if malformed.
static inline BOOL UMMPParseTagString(NSString *tag, uint16_t *group, uint16_t *element)
{
    unsigned g = 0, e = 0;
    if (!tag || sscanf([tag UTF8String], "%x,%x", &g, &e) != 2) return NO;
    *group = (uint16_t)g; *element = (uint16_t)e;
    return YES;
}

#endif
