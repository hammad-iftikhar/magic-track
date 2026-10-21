// Private MultitouchSupport declarations from community reverse engineering, not Apple headers.
// Functions are resolved with dlsym (see TouchEngine.swift), so only types live here.
#pragma once
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int32_t  frame;
    double   timestamp;
    int32_t  identifier;   // stable per finger
    int32_t  state;        // 3-5 down, 6-7 lifting (verify with MAGICTRACK_LOG_TOUCHES=1)
    int32_t  fingerID;
    int32_t  handID;
    MTVector normalized;   // 0...1, y up
    float    size;
    int32_t  zero1;
    float    angle, majorAxis, minorAxis;
    MTVector absolute;     // millimetres
    int32_t  zero2[2];
    float    density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTFrameCallback)(MTDeviceRef, MTTouch *, int32_t count, double timestamp, int32_t frame);

typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(MTDeviceRef, MTFrameCallback);
typedef void (*MTDeviceStartFn)(MTDeviceRef, int32_t mode);
typedef void (*MTDeviceStopFn)(MTDeviceRef);
typedef int (*MTDeviceGetSensorSurfaceDimensionsFn)(MTDeviceRef, int32_t *width, int32_t *height);
