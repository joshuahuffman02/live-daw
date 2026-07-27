#import "AutoMixEngineBridge.h"

#include "Engine.h"
#include "BrainThread.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <mach/mach_time.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <utility>
#include <vector>

static NSString *const AMBridgeErrorDomain = @"AutoMixEngineBridge";
static NSString *const AMSimulatedDeviceUID = @"com.livedaw.automix.simulated-hd96-dante";
static app::Cls classForRole(NSString *role);
static app::Scene sceneForName(NSString *name);
static bool writeFloatWav(const char *path, const float *samples, uint64_t frames, int channels, uint32_t sampleRate);
static UInt32 framesInBufferList(const AudioBufferList *list);
static void clearAudioBufferList(AudioBufferList *output);
static void populateRawInputPointersFromBufferList(const AudioBufferList *input,
                                                   UInt32 frames,
                                                   int channelCount,
                                                   std::vector<std::vector<float>>& scratch,
                                                   std::vector<const float *>& rawInputPtrs,
                                                   const float *silence);
static bool isSimulatedDeviceUID(NSString *uid);
static bool isHD96TargetSampleRate(double sampleRate);
static bool isLivestreamSafeOutputRoute(NSString *inputName,
                                        NSString *inputUID,
                                        NSString *outputName,
                                        NSString *outputUID);
static bool containsStreamOutputKeyword(NSString *text);
static bool containsConsoleRouteKeyword(NSString *text);
static bool containsAnyCaseInsensitive(NSString *text, NSArray<NSString *> *needles);
static NSString *audioFormatSummary(const AudioStreamBasicDescription& format);
static NSString *const AMSupportedFloat32FormatSummary = @"32-bit little-endian float PCM";
static char AMAudioQueueSpecificKey;
static char AMOutputAudioQueueSpecificKey;

#if DEBUG
static std::atomic<uint32_t> AMRealtimeAllocationGuardDepth{0};
static std::atomic<uint64_t> AMRealtimeAllocationsWhileGuarded{0};

static void noteRealtimeAllocationIfGuarded() {
    if (AMRealtimeAllocationGuardDepth.load(std::memory_order_relaxed) > 0) {
        AMRealtimeAllocationsWhileGuarded.fetch_add(1, std::memory_order_relaxed);
    }
}

void* operator new(std::size_t size) {
    noteRealtimeAllocationIfGuarded();
    if (void* p = std::malloc(size)) return p;
    throw std::bad_alloc();
}

void* operator new[](std::size_t size) {
    noteRealtimeAllocationIfGuarded();
    if (void* p = std::malloc(size)) return p;
    throw std::bad_alloc();
}

void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }

struct AMRealtimeAllocationGuard {
    AMRealtimeAllocationGuard() {
        AMRealtimeAllocationsWhileGuarded.store(0, std::memory_order_relaxed);
        AMRealtimeAllocationGuardDepth.fetch_add(1, std::memory_order_relaxed);
    }

    ~AMRealtimeAllocationGuard() {
        AMRealtimeAllocationGuardDepth.fetch_sub(1, std::memory_order_relaxed);
    }
};
#endif

@implementation AMDeviceInfo
- (instancetype)initWithUID:(NSString *)uid
                      name:(NSString *)name
             inputChannels:(NSInteger)inputChannels
            outputChannels:(NSInteger)outputChannels
                sampleRate:(double)sampleRate {
    return [self initWithUID:uid
                        name:name
               inputChannels:inputChannels
              outputChannels:outputChannels
                  sampleRate:sampleRate
          inputFormatSummary:AMSupportedFloat32FormatSummary
         outputFormatSummary:AMSupportedFloat32FormatSummary
        inputFormatSupported:YES
       outputFormatSupported:YES];
}

- (instancetype)initWithUID:(NSString *)uid
                      name:(NSString *)name
             inputChannels:(NSInteger)inputChannels
            outputChannels:(NSInteger)outputChannels
                sampleRate:(double)sampleRate
        inputFormatSummary:(NSString *)inputFormatSummary
       outputFormatSummary:(NSString *)outputFormatSummary
      inputFormatSupported:(BOOL)inputFormatSupported
     outputFormatSupported:(BOOL)outputFormatSupported {
    self = [super init];
    if (self) {
        _uid = [uid copy];
        _name = [name copy];
        _inputChannels = inputChannels;
        _outputChannels = outputChannels;
        _sampleRate = sampleRate;
        _inputFormatSummary = [inputFormatSummary copy];
        _outputFormatSummary = [outputFormatSummary copy];
        _inputFormatSupported = inputFormatSupported;
        _outputFormatSupported = outputFormatSupported;
    }
    return self;
}
@end

@interface AutoMixEngineBridge () {
    AudioDeviceID _deviceID;
    AudioDeviceIOProcID _ioProcID;
    AudioDeviceID _outputDeviceID;
    AudioDeviceIOProcID _outputIOProcID;
    dispatch_queue_t _audioQueue;
    dispatch_queue_t _outputAudioQueue;
    dispatch_queue_t _fileQueue;
    dispatch_source_t _simulationTimer;
    dispatch_source_t _simulationOutputTimer;
    uint64_t _simulationFrame;
    bool _simulationMode;
    bool _separateOutputMode;

    bdsp::Engine _engine;
    app::BrainThread _brain;
    app::Scene _scene;
    bool _brainStarted;

    std::vector<app::Cls> _classes;
    std::array<std::atomic<int>, app::EngineSnapshot::kMaxCh> _pendingClassCodes;
    std::array<std::atomic<int>, app::EngineSnapshot::kMaxCh> _inputChannelIndices;
    std::atomic<bool> _roleConfigDirtyAtomic;
    std::vector<std::vector<float>> _inputScratch;
    std::vector<const float *> _rawInputPtrs;
    std::vector<const float *> _inputPtrs;
    std::vector<float> _outL;
    std::vector<float> _outR;
    std::vector<float> _silence;
    std::vector<float> _outputRingL;
    std::vector<float> _outputRingR;
    uint64_t _outputRingFrameCapacity;
    std::unique_ptr<std::atomic<float>[]> _meterDb;
    std::atomic<float> _outputMeterDbL;
    std::atomic<float> _outputMeterDbR;
    std::atomic<float> _momentaryLufsAtomic;
    std::atomic<float> _shortTermLufsAtomic;
    std::atomic<float> _integratedLufsAtomic;
    std::atomic<float> _limiterGainReductionDbAtomic;

    std::atomic<bool> _runningAtomic;
    std::atomic<bool> _safeBypassAtomic;
    std::atomic<bool> _frozenAtomic;
    std::atomic<bool> _shadowModeAtomic;
    std::atomic<bool> _recordingAtomic;
    std::atomic<bool> _recordReadyToWrite;
    std::atomic<bool> _recordWriteScheduledAtomic;
    std::atomic<bool> _recordWriteInFlightAtomic;
    std::atomic<uint64_t> _recordFrameWriteAtomic;
    std::atomic<uint64_t> _recordFrameCapacityAtomic;
    std::atomic<uint64_t> _dropoutCountAtomic;
    std::atomic<uint64_t> _callbackOverrunCountAtomic;
    std::atomic<uint64_t> _deadlineMissCountAtomic;
    std::atomic<uint64_t> _outputUnderrunCountAtomic;
    std::atomic<uint64_t> _outputOverrunCountAtomic;
    std::atomic<uint64_t> _outputRingReadFrameAtomic;
    std::atomic<uint64_t> _outputRingWriteFrameAtomic;
    std::atomic<uint32_t> _lastCallbackFramesAtomic;
    std::atomic<uint32_t> _maxObservedCallbackFramesAtomic;

    NSInteger _inputChannelCount;
    NSInteger _outputChannelCount;
    NSInteger _bufferFrameSize;
    double _sampleRate;

    std::vector<float> _recordBuffer;
    uint64_t _recordFrameCapacity;
    uint64_t _recordFrameWrite;
    int _recordChannels;
    NSURL *_recordURL;
    NSURL *_finishedRecordingURL;

    uint32_t _machTimeNumer;
    uint32_t _machTimeDenom;
    NSString *_baseStatus;
    NSString *_status;
}
- (BOOL)renderStateIsPreparedForFrames:(UInt32)frames channelCount:(int)chCount;
- (void)clearOutputBufferList:(AudioBufferList *)output;
@end

@implementation AutoMixEngineBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceID = kAudioObjectUnknown;
        _ioProcID = nullptr;
        _outputDeviceID = kAudioObjectUnknown;
        _outputIOProcID = nullptr;
        _audioQueue = dispatch_queue_create("com.livedaw.automix.audio", DISPATCH_QUEUE_SERIAL);
        _outputAudioQueue = dispatch_queue_create("com.livedaw.automix.output", DISPATCH_QUEUE_SERIAL);
        _fileQueue = dispatch_queue_create("com.livedaw.automix.files", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_audioQueue, &AMAudioQueueSpecificKey, &AMAudioQueueSpecificKey, nullptr);
        dispatch_queue_set_specific(_outputAudioQueue, &AMOutputAudioQueueSpecificKey, &AMOutputAudioQueueSpecificKey, nullptr);
        _simulationTimer = nullptr;
        _simulationOutputTimer = nullptr;
        _simulationFrame = 0;
        _simulationMode = false;
        _separateOutputMode = false;
        _scene = app::Scene::Worship;
        _brainStarted = false;
        for (int i = 0; i < app::EngineSnapshot::kMaxCh; ++i) {
            _pendingClassCodes[(size_t)i].store((int)app::Cls::Unknown, std::memory_order_relaxed);
            _inputChannelIndices[(size_t)i].store(i, std::memory_order_relaxed);
        }
        _roleConfigDirtyAtomic.store(false, std::memory_order_relaxed);
        _outputMeterDbL.store(-100.0f, std::memory_order_relaxed);
        _outputMeterDbR.store(-100.0f, std::memory_order_relaxed);
        _momentaryLufsAtomic.store(-100.0f, std::memory_order_relaxed);
        _shortTermLufsAtomic.store(-100.0f, std::memory_order_relaxed);
        _integratedLufsAtomic.store(-100.0f, std::memory_order_relaxed);
        _limiterGainReductionDbAtomic.store(0.0f, std::memory_order_relaxed);
        _runningAtomic.store(false);
        _safeBypassAtomic.store(false);
        _frozenAtomic.store(false);
        _shadowModeAtomic.store(false);
        _recordingAtomic.store(false);
        _recordReadyToWrite.store(false);
        _recordWriteScheduledAtomic.store(false);
        _recordWriteInFlightAtomic.store(false);
        _recordFrameWriteAtomic.store(0);
        _recordFrameCapacityAtomic.store(0);
        _dropoutCountAtomic.store(0);
        _callbackOverrunCountAtomic.store(0);
        _deadlineMissCountAtomic.store(0);
        _outputUnderrunCountAtomic.store(0);
        _outputOverrunCountAtomic.store(0);
        _outputRingReadFrameAtomic.store(0);
        _outputRingWriteFrameAtomic.store(0);
        _lastCallbackFramesAtomic.store(0);
        _maxObservedCallbackFramesAtomic.store(0);
        _outputRingFrameCapacity = 0;
        _inputChannelCount = 0;
        _outputChannelCount = 0;
        _bufferFrameSize = 0;
        _sampleRate = 0;
        _recordFrameCapacity = 0;
        _recordFrameWrite = 0;
        _recordChannels = 0;
        mach_timebase_info_data_t timebase{};
        mach_timebase_info(&timebase);
        _machTimeNumer = timebase.numer ? timebase.numer : 1;
        _machTimeDenom = timebase.denom ? timebase.denom : 1;
        _baseStatus = @"Idle";
        _status = @"Idle";
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSString *)status {
    @synchronized (self) {
        return [_status copy];
    }
}

- (BOOL)running { return _runningAtomic.load(); }
- (BOOL)recording { return _recordingAtomic.load(); }
- (BOOL)recordingSaveInProgress {
    return _recordReadyToWrite.load(std::memory_order_acquire) ||
        _recordWriteScheduledAtomic.load(std::memory_order_acquire) ||
        _recordWriteInFlightAtomic.load(std::memory_order_acquire);
}
- (NSUInteger)recordedFrameCount { return (NSUInteger)_recordFrameWriteAtomic.load(std::memory_order_relaxed); }
- (NSUInteger)recordingTargetFrameCount { return (NSUInteger)_recordFrameCapacityAtomic.load(std::memory_order_relaxed); }
- (double)sampleRate { return _sampleRate; }
- (NSInteger)inputChannelCount { return _inputChannelCount; }
- (NSInteger)bufferFrameSize { return _bufferFrameSize; }
- (NSUInteger)dropoutCount { return (NSUInteger)_dropoutCountAtomic.load(); }
- (NSUInteger)callbackOverrunCount { return (NSUInteger)_callbackOverrunCountAtomic.load(); }
- (NSUInteger)renderDeadlineMissCount { return (NSUInteger)_deadlineMissCountAtomic.load(); }
- (NSUInteger)outputUnderrunCount { return (NSUInteger)_outputUnderrunCountAtomic.load(); }
- (NSUInteger)outputOverrunCount { return (NSUInteger)_outputOverrunCountAtomic.load(); }
- (BOOL)watchdogSafeActive { return _brain.watchdogBypassActive(); }
- (NSInteger)lastCallbackFrameCount { return (NSInteger)_lastCallbackFramesAtomic.load(); }
- (NSInteger)maxObservedCallbackFrameCount { return (NSInteger)_maxObservedCallbackFramesAtomic.load(); }
- (double)momentaryLufs { return (double)_momentaryLufsAtomic.load(std::memory_order_relaxed); }
- (double)shortTermLufs { return (double)_shortTermLufsAtomic.load(std::memory_order_relaxed); }
- (double)integratedLufs { return (double)_integratedLufsAtomic.load(std::memory_order_relaxed); }
- (double)limiterGainReductionDb { return (double)_limiterGainReductionDbAtomic.load(std::memory_order_relaxed); }
- (double)currentBpm { return _brainStarted ? (double)_brain.currentBpm() : 0.0; }
- (double)currentBpmConfidence { return _brainStarted ? (double)_brain.currentBpmConfidence() : 0.0; }
- (double)autoLoudnessTrimDb { return (double)_brain.currentAutoLoudnessTrimDb(); }
- (BOOL)shadowModeEnabled { return _shadowModeAtomic.load(std::memory_order_relaxed); }
- (double)autoTrimDbForChannel:(NSInteger)channel {
    return (double)_brain.currentAutoTrimDb((int)channel);
}
- (double)autoFaderDbForChannel:(NSInteger)channel {
    return (double)_brain.currentAutoFaderDb((int)channel);
}
- (double)learnedNoiseFloorDbForChannel:(NSInteger)channel {
    return (double)_brain.currentNoiseFloorDb((int)channel);
}
- (BOOL)autoChannelActiveForChannel:(NSInteger)channel {
    return _brain.channelActive((int)channel);
}

+ (BOOL)isSupportedCoreAudioPCMFormatID:(uint32_t)formatID
                                  flags:(uint32_t)formatFlags
                         bitsPerChannel:(uint32_t)bitsPerChannel {
    return formatID == kAudioFormatLinearPCM &&
        (formatFlags & kAudioFormatFlagIsFloat) != 0 &&
        (formatFlags & kAudioFormatFlagIsBigEndian) == 0 &&
        bitsPerChannel == 32;
}

+ (BOOL)isHD96TargetSampleRate:(double)sampleRate {
    return isHD96TargetSampleRate(sampleRate);
}

+ (BOOL)isLivestreamSafeOutputRouteForInputName:(NSString *)inputName
                                       inputUID:(NSString *)inputUID
                                     outputName:(NSString *)outputName
                                      outputUID:(NSString *)outputUID {
    return isLivestreamSafeOutputRoute(inputName, inputUID, outputName, outputUID);
}

#if DEBUG
+ (NSArray<NSArray<NSNumber *> *> *)debugExtractFloat32InputChannelsFromBuffers:(NSArray<NSArray<NSNumber *> *> *)buffers
                                                                   channelCounts:(NSArray<NSNumber *> *)channelCounts
                                                                expectedChannels:(NSInteger)expectedChannels
                                                                          frames:(NSInteger)frames {
    const UInt32 safeFrames = (UInt32)std::max<NSInteger>(0, frames);
    const int safeChannels = (int)std::max<NSInteger>(0, std::min<NSInteger>(expectedChannels, app::EngineSnapshot::kMaxCh));

    std::vector<std::vector<float>> sampleStorage((size_t)buffers.count);
    const UInt32 bufferCount = (UInt32)buffers.count;
    const size_t listBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * std::max<UInt32>(1, bufferCount);
    std::vector<uint8_t> listStorage(listBytes, 0);
    AudioBufferList *list = (AudioBufferList *)listStorage.data();
    list->mNumberBuffers = bufferCount;

    for (UInt32 b = 0; b < bufferCount; ++b) {
        NSArray<NSNumber *> *buffer = buffers[(NSUInteger)b];
        std::vector<float>& samples = sampleStorage[(size_t)b];
        samples.reserve((size_t)buffer.count);
        for (NSNumber *value in buffer) samples.push_back(value.floatValue);

        UInt32 channelCount = 1;
        if (b < channelCounts.count) {
            channelCount = (UInt32)std::max<NSInteger>(0, channelCounts[(NSUInteger)b].integerValue);
        }
        list->mBuffers[b].mNumberChannels = channelCount;
        list->mBuffers[b].mDataByteSize = (UInt32)(samples.size() * sizeof(float));
        list->mBuffers[b].mData = samples.empty() ? nullptr : samples.data();
    }

    std::vector<std::vector<float>> scratch((size_t)safeChannels, std::vector<float>((size_t)safeFrames, 0.0f));
    std::vector<const float *> rawInputPtrs((size_t)safeChannels, nullptr);
    std::vector<float> silence((size_t)safeFrames, 0.0f);
    populateRawInputPointersFromBufferList(list,
                                           safeFrames,
                                           safeChannels,
                                           scratch,
                                           rawInputPtrs,
                                           silence.data());

    NSMutableArray<NSArray<NSNumber *> *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)safeChannels];
    for (int ch = 0; ch < safeChannels; ++ch) {
        const float *src = rawInputPtrs[(size_t)ch] ? rawInputPtrs[(size_t)ch] : silence.data();
        NSMutableArray<NSNumber *> *channel = [NSMutableArray arrayWithCapacity:(NSUInteger)safeFrames];
        for (UInt32 frame = 0; frame < safeFrames; ++frame) {
            [channel addObject:@(src[frame])];
        }
        [result addObject:channel];
    }
    return result;
}

- (NSUInteger)debugRunRealtimeNoAllocationProbeWithFrameCount:(NSUInteger)frameCount
                                                        blocks:(NSUInteger)blocks {
    if (!_runningAtomic.load(std::memory_order_acquire) || !_simulationMode || !_audioQueue) {
        return NSUIntegerMax;
    }

    const UInt32 safeFrames = (UInt32)std::max<NSUInteger>(1, frameCount);
    const NSUInteger safeBlocks = std::max<NSUInteger>(1, blocks);
    __block NSUInteger guardedAllocations = NSUIntegerMax;

    dispatch_sync(_audioQueue, ^{
        {
            AMRealtimeAllocationGuard guard;
            for (NSUInteger block = 0; block < safeBlocks; ++block) {
                [self renderSimulatedFrames:safeFrames];
            }
            guardedAllocations = (NSUInteger)AMRealtimeAllocationsWhileGuarded.load(std::memory_order_relaxed);
        }
    });

    return guardedAllocations;
}

- (NSUInteger)debugRunRealtimeCoreAudioInputNoAllocationProbeWithFrameCount:(NSUInteger)frameCount
                                                                      blocks:(NSUInteger)blocks
                                                           channelsPerBuffer:(NSUInteger)channelsPerBuffer {
    if (!_runningAtomic.load(std::memory_order_acquire) || !_audioQueue) {
        return NSUIntegerMax;
    }

    const UInt32 safeFrames = (UInt32)std::min<NSUInteger>(
        std::max<NSUInteger>(1, frameCount),
        (NSUInteger)std::numeric_limits<UInt32>::max()
    );
    const NSUInteger safeBlocks = std::max<NSUInteger>(1, blocks);
    const int channelCount = (int)std::max<NSInteger>(1, _inputChannelCount);
    const UInt32 requestedChannelsPerBuffer = (UInt32)std::max<NSUInteger>(1, channelsPerBuffer);
    const UInt32 channelsPerAudioBuffer = std::min<UInt32>((UInt32)channelCount, requestedChannelsPerBuffer);
    const UInt32 inputBufferCount = (UInt32)((channelCount + (int)channelsPerAudioBuffer - 1) / (int)channelsPerAudioBuffer);
    const size_t inputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * inputBufferCount;
    const size_t outputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * 2u;
    std::vector<uint8_t> inputListStorage(inputListBytes, 0);
    std::vector<uint8_t> outputListStorage(outputListBytes, 0);
    std::vector<std::vector<float>> inputSamples((size_t)inputBufferCount);
    std::vector<float> outputL((size_t)safeFrames, 0.0f);
    std::vector<float> outputR((size_t)safeFrames, 0.0f);

    AudioBufferList *inputList = (AudioBufferList *)inputListStorage.data();
    inputList->mNumberBuffers = inputBufferCount;
    int nextChannel = 0;
    for (UInt32 b = 0; b < inputBufferCount; ++b) {
        const UInt32 channels = std::min<UInt32>(channelsPerAudioBuffer, (UInt32)(channelCount - nextChannel));
        std::vector<float>& samples = inputSamples[(size_t)b];
        samples.assign((size_t)safeFrames * (size_t)channels, 0.0f);
        inputList->mBuffers[b].mNumberChannels = channels;
        inputList->mBuffers[b].mDataByteSize = (UInt32)(samples.size() * sizeof(float));
        inputList->mBuffers[b].mData = samples.data();
        nextChannel += (int)channels;
    }

    AudioBufferList *outputList = (AudioBufferList *)outputListStorage.data();
    outputList->mNumberBuffers = 2;
    outputList->mBuffers[0].mNumberChannels = 1;
    outputList->mBuffers[0].mDataByteSize = (UInt32)(outputL.size() * sizeof(float));
    outputList->mBuffers[0].mData = outputL.data();
    outputList->mBuffers[1].mNumberChannels = 1;
    outputList->mBuffers[1].mDataByteSize = (UInt32)(outputR.size() * sizeof(float));
    outputList->mBuffers[1].mData = outputR.data();

    __block NSUInteger guardedAllocations = NSUIntegerMax;
    dispatch_sync(_audioQueue, ^{
        {
            AMRealtimeAllocationGuard guard;
            for (NSUInteger block = 0; block < safeBlocks; ++block) {
                for (UInt32 b = 0; b < inputBufferCount; ++b) {
                    AudioBuffer &buffer = inputList->mBuffers[b];
                    float *samples = (float *)buffer.mData;
                    const UInt32 channels = buffer.mNumberChannels;
                    for (UInt32 frame = 0; frame < safeFrames; ++frame) {
                        for (UInt32 channel = 0; channel < channels; ++channel) {
                            const float sign = ((frame + channel + (UInt32)block) % 2u) == 0 ? 1.0f : -1.0f;
                            samples[(size_t)frame * channels + channel] = sign * (0.01f + 0.001f * (float)((channel + b) % 7u));
                        }
                    }
                }
                [self renderInput:inputList output:outputList frames:safeFrames];
            }
            guardedAllocations = (NSUInteger)AMRealtimeAllocationsWhileGuarded.load(std::memory_order_relaxed);
        }
    });

    return guardedAllocations;
}

- (NSArray<NSArray<NSNumber *> *> *)debugRenderCoreAudioMonoOutputBuffersWithFrameCount:(NSUInteger)frameCount
                                                                      outputBufferCount:(NSUInteger)outputBufferCount {
    if (!_runningAtomic.load(std::memory_order_acquire) || !_audioQueue) {
        return @[];
    }

    const UInt32 safeFrames = (UInt32)std::max<NSUInteger>(1, frameCount);
    const UInt32 outputBuffers = (UInt32)std::max<NSUInteger>(1, outputBufferCount);
    const int channelCount = (int)std::max<NSInteger>(1, _inputChannelCount);
    const size_t inputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
    const size_t outputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * outputBuffers;
    std::vector<uint8_t> inputListStorage(inputListBytes, 0);
    std::vector<uint8_t> outputListStorage(outputListBytes, 0);
    std::vector<float> inputSamples((size_t)safeFrames * (size_t)channelCount, 0.0f);
    std::vector<std::vector<float>> outputSamples((size_t)outputBuffers, std::vector<float>((size_t)safeFrames, 0.0f));

    for (UInt32 frame = 0; frame < safeFrames; ++frame) {
        for (int channel = 0; channel < channelCount; ++channel) {
            const float sign = ((frame + (UInt32)channel) % 2u) == 0 ? 1.0f : -1.0f;
            inputSamples[(size_t)frame * (size_t)channelCount + (size_t)channel] = sign * (0.02f + 0.001f * (float)(channel % 9));
        }
    }

    AudioBufferList *inputList = (AudioBufferList *)inputListStorage.data();
    inputList->mNumberBuffers = 1;
    inputList->mBuffers[0].mNumberChannels = (UInt32)channelCount;
    inputList->mBuffers[0].mDataByteSize = (UInt32)(inputSamples.size() * sizeof(float));
    inputList->mBuffers[0].mData = inputSamples.data();

    AudioBufferList *outputList = (AudioBufferList *)outputListStorage.data();
    outputList->mNumberBuffers = outputBuffers;
    for (UInt32 b = 0; b < outputBuffers; ++b) {
        outputList->mBuffers[b].mNumberChannels = 1;
        outputList->mBuffers[b].mDataByteSize = (UInt32)(outputSamples[(size_t)b].size() * sizeof(float));
        outputList->mBuffers[b].mData = outputSamples[(size_t)b].data();
    }

    dispatch_sync(_audioQueue, ^{
        [self renderInput:inputList output:outputList frames:safeFrames];
    });

    NSMutableArray<NSArray<NSNumber *> *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)outputBuffers];
    for (UInt32 b = 0; b < outputBuffers; ++b) {
        NSMutableArray<NSNumber *> *buffer = [NSMutableArray arrayWithCapacity:(NSUInteger)safeFrames];
        const std::vector<float>& samples = outputSamples[(size_t)b];
        for (UInt32 frame = 0; frame < safeFrames; ++frame) {
            [buffer addObject:@(samples[(size_t)frame])];
        }
        [result addObject:buffer];
    }
    return result;
}

- (NSArray<NSArray<NSNumber *> *> *)debugRenderCoreAudioInterleavedOutputChannelsWithFrameCount:(NSUInteger)frameCount
                                                                             outputChannelCount:(NSUInteger)outputChannelCount {
    if (!_runningAtomic.load(std::memory_order_acquire) || !_audioQueue) {
        return @[];
    }

    const UInt32 safeFrames = (UInt32)std::max<NSUInteger>(1, frameCount);
    const UInt32 outputChannels = (UInt32)std::max<NSUInteger>(1, outputChannelCount);
    const int channelCount = (int)std::max<NSInteger>(1, _inputChannelCount);
    const size_t inputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
    const size_t outputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
    std::vector<uint8_t> inputListStorage(inputListBytes, 0);
    std::vector<uint8_t> outputListStorage(outputListBytes, 0);
    std::vector<float> inputSamples((size_t)safeFrames * (size_t)channelCount, 0.0f);
    std::vector<float> outputSamples((size_t)safeFrames * (size_t)outputChannels, 0.5f);

    for (UInt32 frame = 0; frame < safeFrames; ++frame) {
        for (int channel = 0; channel < channelCount; ++channel) {
            const float sign = ((frame + (UInt32)channel) % 2u) == 0 ? 1.0f : -1.0f;
            inputSamples[(size_t)frame * (size_t)channelCount + (size_t)channel] = sign * (0.02f + 0.001f * (float)(channel % 9));
        }
    }

    AudioBufferList *inputList = (AudioBufferList *)inputListStorage.data();
    inputList->mNumberBuffers = 1;
    inputList->mBuffers[0].mNumberChannels = (UInt32)channelCount;
    inputList->mBuffers[0].mDataByteSize = (UInt32)(inputSamples.size() * sizeof(float));
    inputList->mBuffers[0].mData = inputSamples.data();

    AudioBufferList *outputList = (AudioBufferList *)outputListStorage.data();
    outputList->mNumberBuffers = 1;
    outputList->mBuffers[0].mNumberChannels = outputChannels;
    outputList->mBuffers[0].mDataByteSize = (UInt32)(outputSamples.size() * sizeof(float));
    outputList->mBuffers[0].mData = outputSamples.data();

    dispatch_sync(_audioQueue, ^{
        [self renderInput:inputList output:outputList frames:safeFrames];
    });

    NSMutableArray<NSArray<NSNumber *> *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)outputChannels];
    for (UInt32 channel = 0; channel < outputChannels; ++channel) {
        NSMutableArray<NSNumber *> *samples = [NSMutableArray arrayWithCapacity:(NSUInteger)safeFrames];
        for (UInt32 frame = 0; frame < safeFrames; ++frame) {
            [samples addObject:@(outputSamples[(size_t)frame * (size_t)outputChannels + channel])];
        }
        [result addObject:samples];
    }
    return result;
}

- (NSArray<NSArray<NSNumber *> *> *)debugRenderCoreAudioMonoOutputBuffersWithFrameCount:(NSUInteger)frameCount
                                                                      outputBufferCount:(NSUInteger)outputBufferCount
                                                                     activeInputChannel:(NSInteger)activeInputChannel
                                                                           warmupBlocks:(NSUInteger)warmupBlocks {
    if (!_runningAtomic.load(std::memory_order_acquire) || !_audioQueue) {
        return @[];
    }

    const UInt32 safeFrames = (UInt32)std::max<NSUInteger>(
        1,
        std::min<NSUInteger>(frameCount, (NSUInteger)std::max<NSInteger>(1, _bufferFrameSize))
    );
    const UInt32 outputBuffers = (UInt32)std::max<NSUInteger>(1, outputBufferCount);
    const int channelCount = (int)std::max<NSInteger>(1, _inputChannelCount);
    const bool hasActiveInput = activeInputChannel >= 0 && activeInputChannel < channelCount;
    const double sampleRate = _sampleRate > 0 ? _sampleRate : 96000.0;
    const double twoPi = 6.28318530717958647692;
    const size_t inputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
    const size_t outputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * outputBuffers;
    std::vector<uint8_t> inputListStorage(inputListBytes, 0);
    std::vector<uint8_t> outputListStorage(outputListBytes, 0);
    std::vector<float> inputSamples((size_t)safeFrames * (size_t)channelCount, 0.0f);
    std::vector<std::vector<float>> outputSamples((size_t)outputBuffers, std::vector<float>((size_t)safeFrames, 0.0f));

    if (hasActiveInput) {
        for (UInt32 frame = 0; frame < safeFrames; ++frame) {
            const double t = (double)frame / sampleRate;
            inputSamples[(size_t)frame * (size_t)channelCount + (size_t)activeInputChannel] =
                0.2f * (float)std::sin(twoPi * 1000.0 * t);
        }
    }

    AudioBufferList *inputList = (AudioBufferList *)inputListStorage.data();
    inputList->mNumberBuffers = 1;
    inputList->mBuffers[0].mNumberChannels = (UInt32)channelCount;
    inputList->mBuffers[0].mDataByteSize = (UInt32)(inputSamples.size() * sizeof(float));
    inputList->mBuffers[0].mData = inputSamples.data();

    AudioBufferList *outputList = (AudioBufferList *)outputListStorage.data();
    outputList->mNumberBuffers = outputBuffers;
    for (UInt32 b = 0; b < outputBuffers; ++b) {
        outputList->mBuffers[b].mNumberChannels = 1;
        outputList->mBuffers[b].mDataByteSize = (UInt32)(outputSamples[(size_t)b].size() * sizeof(float));
        outputList->mBuffers[b].mData = outputSamples[(size_t)b].data();
    }

    const NSUInteger renderBlocks = std::max<NSUInteger>(1, warmupBlocks + 1);
    dispatch_sync(_audioQueue, ^{
        for (NSUInteger block = 0; block < renderBlocks; ++block) {
            [self renderInput:inputList output:outputList frames:safeFrames];
        }
    });

    NSMutableArray<NSArray<NSNumber *> *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)outputBuffers];
    for (UInt32 b = 0; b < outputBuffers; ++b) {
        NSMutableArray<NSNumber *> *buffer = [NSMutableArray arrayWithCapacity:(NSUInteger)safeFrames];
        const std::vector<float>& samples = outputSamples[(size_t)b];
        for (UInt32 frame = 0; frame < safeFrames; ++frame) {
            [buffer addObject:@(samples[(size_t)frame])];
        }
        [result addObject:buffer];
    }
    return result;
}

- (NSArray<NSNumber *> *)debugRenderCoreAudioInputLevelsWithFrameCount:(NSUInteger)frameCount
                                                    activeInputChannel:(NSInteger)activeInputChannel {
    if (!_runningAtomic.load(std::memory_order_acquire) || !_audioQueue) return @[];

    const UInt32 safeFrames = (UInt32)std::max<NSUInteger>(
        1,
        std::min<NSUInteger>(frameCount, (NSUInteger)std::max<NSInteger>(1, _bufferFrameSize))
    );
    const int channelCount = (int)std::max<NSInteger>(1, _inputChannelCount);
    if (activeInputChannel < 0 || activeInputChannel >= channelCount) return @[];

    const double sampleRate = _sampleRate > 0 ? _sampleRate : 96000.0;
    const double twoPi = 6.28318530717958647692;
    const size_t inputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
    std::vector<uint8_t> inputListStorage(inputListBytes, 0);
    std::vector<float> inputSamples((size_t)safeFrames * (size_t)channelCount, 0.0f);
    for (UInt32 frame = 0; frame < safeFrames; ++frame) {
        const double t = (double)frame / sampleRate;
        inputSamples[(size_t)frame * (size_t)channelCount + (size_t)activeInputChannel] =
            0.2f * (float)std::sin(twoPi * 1000.0 * t);
    }

    AudioBufferList *inputList = (AudioBufferList *)inputListStorage.data();
    inputList->mNumberBuffers = 1;
    inputList->mBuffers[0].mNumberChannels = (UInt32)channelCount;
    inputList->mBuffers[0].mDataByteSize = (UInt32)(inputSamples.size() * sizeof(float));
    inputList->mBuffers[0].mData = inputSamples.data();

    __block std::vector<float> captured((size_t)channelCount, -100.0f);
    dispatch_sync(_audioQueue, ^{
        [self renderInput:inputList output:nullptr frames:safeFrames];
        for (int channel = 0; channel < channelCount; ++channel) {
            captured[(size_t)channel] = _meterDb[(size_t)channel].load(std::memory_order_relaxed);
        }
    });

    NSMutableArray<NSNumber *> *levels = [NSMutableArray arrayWithCapacity:(NSUInteger)channelCount];
    for (float level : captured) [levels addObject:@(level)];
    return levels;
}

- (NSArray<NSArray<NSNumber *> *> *)debugRenderSeparateCoreAudioInterleavedOutputChannelsWithFrameCount:(NSUInteger)frameCount
                                                                                      outputChannelCount:(NSUInteger)outputChannelCount
                                                                                            warmupBlocks:(NSUInteger)warmupBlocks {
    if (!_runningAtomic.load(std::memory_order_acquire) || !_audioQueue || !_outputAudioQueue) {
        return @[];
    }

    const UInt32 safeFrames = (UInt32)std::max<NSUInteger>(
        1,
        std::min<NSUInteger>(frameCount, (NSUInteger)std::max<NSInteger>(1, _bufferFrameSize))
    );
    const UInt32 outputChannels = (UInt32)std::max<NSUInteger>(1, outputChannelCount);
    (void)warmupBlocks;
    const size_t outputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
    std::vector<uint8_t> outputListStorage(outputListBytes, 0);
    std::vector<float> outputSamples((size_t)safeFrames * (size_t)outputChannels, 0.5f);

    AudioBufferList *outputList = (AudioBufferList *)outputListStorage.data();
    outputList->mNumberBuffers = 1;
    outputList->mBuffers[0].mNumberChannels = outputChannels;
    outputList->mBuffers[0].mDataByteSize = (UInt32)(outputSamples.size() * sizeof(float));
    outputList->mBuffers[0].mData = outputSamples.data();

    dispatch_sync(_outputAudioQueue, ^{
        if (_outputRingFrameCapacity < safeFrames ||
            _outputRingL.size() < safeFrames ||
            _outputRingR.size() < safeFrames) {
            _outputRingFrameCapacity = safeFrames;
            _outputRingL.assign((size_t)safeFrames, 0.0f);
            _outputRingR.assign((size_t)safeFrames, 0.0f);
        }
        for (UInt32 frame = 0; frame < safeFrames; ++frame) {
            const float sign = (frame % 2u) == 0 ? 1.0f : -1.0f;
            _outputRingL[(size_t)frame] = 0.08f * sign;
            _outputRingR[(size_t)frame] = 0.05f * -sign;
        }
        [self writeSeparateOutputBufferList:outputList readFrame:0 frames:safeFrames framesToRead:safeFrames];
    });

    NSMutableArray<NSArray<NSNumber *> *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)outputChannels];
    for (UInt32 channel = 0; channel < outputChannels; ++channel) {
        NSMutableArray<NSNumber *> *samples = [NSMutableArray arrayWithCapacity:(NSUInteger)safeFrames];
        for (UInt32 frame = 0; frame < safeFrames; ++frame) {
            [samples addObject:@(outputSamples[(size_t)frame * (size_t)outputChannels + channel])];
        }
        [result addObject:samples];
    }
    return result;
}

- (NSArray<NSNumber *> *)debugCaptureRecordingFirstInputFrameWithFrameCount:(NSUInteger)frameCount
                                                          channelsPerBuffer:(NSUInteger)channelsPerBuffer {
    if (!_runningAtomic.load(std::memory_order_acquire) || !_audioQueue) {
        return @[];
    }

    const UInt32 safeFrames = (UInt32)std::max<NSUInteger>(
        1,
        std::min<NSUInteger>(frameCount, (NSUInteger)std::max<NSInteger>(1, _bufferFrameSize))
    );
    const int channelCount = (int)std::max<NSInteger>(1, _inputChannelCount);
    const UInt32 requestedChannelsPerBuffer = (UInt32)std::max<NSUInteger>(1, channelsPerBuffer);
    const UInt32 channelsPerAudioBuffer = std::min<UInt32>((UInt32)channelCount, requestedChannelsPerBuffer);
    const UInt32 inputBufferCount = (UInt32)((channelCount + (int)channelsPerAudioBuffer - 1) / (int)channelsPerAudioBuffer);
    const size_t inputListBytes = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * inputBufferCount;
    std::vector<uint8_t> inputListStorage(inputListBytes, 0);
    std::vector<std::vector<float>> inputSamples((size_t)inputBufferCount);

    AudioBufferList *inputList = (AudioBufferList *)inputListStorage.data();
    inputList->mNumberBuffers = inputBufferCount;
    int nextChannel = 0;
    for (UInt32 b = 0; b < inputBufferCount; ++b) {
        const UInt32 channels = std::min<UInt32>(channelsPerAudioBuffer, (UInt32)(channelCount - nextChannel));
        std::vector<float>& samples = inputSamples[(size_t)b];
        samples.assign((size_t)safeFrames * (size_t)channels, 0.0f);
        for (UInt32 frame = 0; frame < safeFrames; ++frame) {
            for (UInt32 channel = 0; channel < channels; ++channel) {
                const UInt32 rawChannel = (UInt32)nextChannel + channel;
                samples[(size_t)frame * channels + channel] = 0.01f * (float)(rawChannel + 1u);
            }
        }
        inputList->mBuffers[b].mNumberChannels = channels;
        inputList->mBuffers[b].mDataByteSize = (UInt32)(samples.size() * sizeof(float));
        inputList->mBuffers[b].mData = samples.data();
        nextChannel += (int)channels;
    }

    __block std::vector<float> firstFrame;
    dispatch_sync(_audioQueue, ^{
        const int recordChannels = channelCount + 2;
        _recordChannels = recordChannels;
        _recordFrameCapacity = safeFrames;
        _recordFrameWrite = 0;
        _recordFrameCapacityAtomic.store(_recordFrameCapacity, std::memory_order_relaxed);
        _recordFrameWriteAtomic.store(0, std::memory_order_relaxed);
        _recordBuffer.assign((size_t)safeFrames * (size_t)recordChannels, 0.0f);
        _recordingAtomic.store(true, std::memory_order_release);
        _recordReadyToWrite.store(false, std::memory_order_release);
        _recordWriteScheduledAtomic.store(false, std::memory_order_release);
        _recordWriteInFlightAtomic.store(false, std::memory_order_release);

        [self renderInput:inputList output:nullptr frames:safeFrames];

        firstFrame.assign(_recordBuffer.begin(), _recordBuffer.begin() + channelCount);
        _recordingAtomic.store(false, std::memory_order_release);
        _recordReadyToWrite.store(false, std::memory_order_release);
        _recordFrameCapacityAtomic.store(0, std::memory_order_relaxed);
        _recordFrameWriteAtomic.store(0, std::memory_order_relaxed);
    });

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)firstFrame.size()];
    for (float sample : firstFrame) {
        [result addObject:@(sample)];
    }
    return result;
}

- (void)debugSetBrainTickPausedForWatchdogProbe:(BOOL)paused {
    _brain.debugSetTickPausedForTesting(paused);
}
#endif

- (void)setStatus:(NSString *)status {
    @synchronized (self) {
        _baseStatus = [status copy];
        _status = [status copy];
    }
}

- (void)refreshStatusFromRealtimeCounters {
    @synchronized (self) {
        const uint64_t dropouts = _dropoutCountAtomic.load();
        const uint64_t underruns = _outputUnderrunCountAtomic.load();
        const uint64_t overruns = _outputOverrunCountAtomic.load();
        const bool watchdogSafe = _brain.watchdogBypassActive();
        if (watchdogSafe && dropouts == 0) {
            _status = [NSString stringWithFormat:@"%@ - WATCHDOG SAFE active", _baseStatus];
            return;
        }
        if (dropouts == 0) {
            _status = [_baseStatus copy];
            return;
        }
        if (underruns > 0 || overruns > 0) {
            NSString *prefix = watchdogSafe ? @"WATCHDOG SAFE active, " : @"";
            _status = [NSString stringWithFormat:@"%@ - audio warnings: %@%llu total, output %llu underruns/%llu overruns",
                       _baseStatus,
                       prefix,
                       (unsigned long long)dropouts,
                       (unsigned long long)underruns,
                       (unsigned long long)overruns];
            return;
        }
        NSString *prefix = watchdogSafe ? @"WATCHDOG SAFE active, " : @"";
        _status = [NSString stringWithFormat:@"%@ - audio warnings: %@%llu dropouts/overruns",
                   _baseStatus, prefix, (unsigned long long)dropouts];
    }
}

- (NSArray<AMDeviceInfo *> *)availableDevices {
    NSMutableArray<AMDeviceInfo *> *result = [NSMutableArray array];
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &dataSize);
    if (status == noErr && dataSize > 0) {
        const UInt32 count = dataSize / sizeof(AudioDeviceID);
        std::vector<AudioDeviceID> devices(count);
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &dataSize, devices.data());
        if (status == noErr) {
            for (AudioDeviceID device : devices) {
                AMDeviceInfo *info = [self deviceInfoForDevice:device];
                if (info) [result addObject:info];
            }
        }
    }

    [result addObject:[self simulatedDeviceInfo]];
    return result;
}

- (AMDeviceInfo *)runningInputDeviceInfo {
    if (!_runningAtomic.load(std::memory_order_acquire)) return nil;
    if (_simulationMode) return [self simulatedDeviceInfo];
    if (_deviceID == kAudioObjectUnknown) return nil;
    return [self deviceInfoForDevice:_deviceID];
}

- (AMDeviceInfo *)runningOutputDeviceInfo {
    if (!_runningAtomic.load(std::memory_order_acquire)) return nil;
    if (_simulationMode) return [self simulatedDeviceInfo];
    AudioDeviceID outputDevice = _separateOutputMode ? _outputDeviceID : _deviceID;
    if (outputDevice == kAudioObjectUnknown) return nil;
    return [self deviceInfoForDevice:outputDevice];
}

- (BOOL)startWithInputDeviceUID:(NSString *)uid
                outputDeviceUID:(NSString *)outputUID
                   channelRoles:(NSArray<NSString *> *)roles
             inputChannelIndices:(NSArray<NSNumber *> *)inputChannelIndices
                          error:(NSError **)error {
    return [self startWithInputDeviceUID:uid
                        outputDeviceUID:outputUID
                           channelRoles:roles
                     inputChannelIndices:inputChannelIndices
                              rehearsal:NO
                                  error:error];
}

- (BOOL)startWithInputDeviceUID:(NSString *)uid
                outputDeviceUID:(NSString *)outputUID
                   channelRoles:(NSArray<NSString *> *)roles
             inputChannelIndices:(NSArray<NSNumber *> *)inputChannelIndices
                      rehearsal:(BOOL)rehearsal
                          error:(NSError **)error {
    if (_runningAtomic.load()) [self stop];

    if (isSimulatedDeviceUID(uid)) {
        return [self startSimulatedWithChannelCount:64
                                        sampleRate:96000.0
                                   bufferFrameSize:256
                                       channelRoles:roles
                                inputChannelIndices:inputChannelIndices
                                              error:error];
    }

    AudioDeviceID inputDevice = [self deviceForUID:uid];
    if (inputDevice == kAudioObjectUnknown) {
        [self fail:error message:@"Selected Core Audio input device was not found."];
        return NO;
    }
    const BOOL separateOutput = outputUID.length > 0 && ![outputUID isEqualToString:uid];
    AudioDeviceID outputDevice = separateOutput ? [self deviceForUID:outputUID] : inputDevice;
    if (outputDevice == kAudioObjectUnknown) {
        [self fail:error message:@"Selected Core Audio output device was not found."];
        return NO;
    }

    NSString *inputName = [self stringProperty:kAudioObjectPropertyName forDevice:inputDevice fallback:@"Unknown Device"];
    NSString *outputName = [self stringProperty:kAudioObjectPropertyName forDevice:outputDevice fallback:@"Unknown Device"];
    NSString *effectiveOutputUID = outputUID.length > 0 ? outputUID : uid;
    if (rehearsal) {
        // Rehearsal: allow any separate, non-Dante output (e.g. built-in speakers,
        // BlackHole, an Aggregate) so the operator can monitor — but never route the
        // mix back into the Dante/HD96 input itself.
        NSString *outputHaystack = [[NSString stringWithFormat:@"%@ %@", outputName, effectiveOutputUID] lowercaseString];
        if (!separateOutput || [outputHaystack containsString:@"dante"]) {
            [self fail:error message:@"Rehearsal output must be a separate, non-Dante device (e.g. built-in speakers, BlackHole, Loopback, or an Aggregate Device), not the Dante/HD96 input."];
            return NO;
        }
    } else if (!isLivestreamSafeOutputRoute(inputName, uid, outputName, effectiveOutputUID)) {
        [self fail:error message:@"Selected Core Audio output route is not isolated for livestream. Use a stream encoder, BlackHole, Loopback, OBS, or a stream-safe Aggregate Device instead of the HD96/Dante/FOH route."];
        return NO;
    }

    const NSInteger inputChannels = [self channelCountForDevice:inputDevice scope:kAudioDevicePropertyScopeInput];
    const NSInteger outputChannels = [self channelCountForDevice:outputDevice scope:kAudioDevicePropertyScopeOutput];
    const double sampleRate = [self nominalSampleRateForDevice:inputDevice];
    const double outputSampleRate = [self nominalSampleRateForDevice:outputDevice];
    const NSInteger bufferFrames = [self bufferFrameSizeForDevice:inputDevice];
    const NSInteger outputBufferFrames = [self bufferFrameSizeForDevice:outputDevice];
    if (inputChannels <= 0) {
        [self fail:error message:@"Selected device has no input channels."];
        return NO;
    }
    if (outputChannels < 2) {
        [self fail:error message:@"Selected device needs at least two output channels for the stream mix."];
        return NO;
    }
    if (sampleRate <= 0 || outputSampleRate <= 0 || bufferFrames <= 0 || outputBufferFrames <= 0) {
        [self fail:error message:@"Could not read the selected device sample rate or buffer size."];
        return NO;
    }
    if (std::abs(sampleRate - outputSampleRate) >= 1.0) {
        [self fail:error message:[NSString stringWithFormat:@"Input/output sample-rate mismatch: input %.0f Hz, output %.0f Hz. Match devices to 96 kHz or use an Aggregate Device.", sampleRate, outputSampleRate]];
        return NO;
    }
    if (!rehearsal && (!isHD96TargetSampleRate(sampleRate) || !isHD96TargetSampleRate(outputSampleRate))) {
        [self fail:error message:[NSString stringWithFormat:@"Selected Core Audio route is %.0f Hz input / %.0f Hz output. HD96/Dante must be clocked at 96000 Hz before starting the stream mix.", sampleRate, outputSampleRate]];
        return NO;
    }
    NSString *formatError = nil;
    if (![self validateDeviceFloat32Format:inputDevice
                                     scope:kAudioDevicePropertyScopeInput
                                      role:@"input"
                              errorMessage:&formatError]) {
        [self fail:error message:formatError ?: @"Selected Core Audio input device is not in a supported float format."];
        return NO;
    }
    if (![self validateDeviceFloat32Format:outputDevice
                                     scope:kAudioDevicePropertyScopeOutput
                                      role:@"output"
                              errorMessage:&formatError]) {
        [self fail:error message:formatError ?: @"Selected Core Audio output device is not in a supported float format."];
        return NO;
    }

    _deviceID = inputDevice;
    _outputDeviceID = separateOutput ? outputDevice : kAudioObjectUnknown;
    _simulationMode = false;
    _separateOutputMode = separateOutput;
    [self resetRealtimeCounters];
    if (![self prepareEngineWithInputChannels:inputChannels
                               outputChannels:outputChannels
                                   sampleRate:sampleRate
                              bufferFrameSize:bufferFrames
                                 channelRoles:roles
                          inputChannelIndices:inputChannelIndices
                                        error:error]) {
        return NO;
    }
    if (separateOutput) {
        [self prepareSeparateOutputRingWithSampleRate:sampleRate
                                    inputBufferFrames:bufferFrames
                                   outputBufferFrames:outputBufferFrames];
    }

    __unsafe_unretained AutoMixEngineBridge *unsafeSelf = self;
    OSStatus status = AudioDeviceCreateIOProcIDWithBlock(&_ioProcID, inputDevice, _audioQueue, ^(const AudioTimeStamp *inNow,
                                                                                                 const AudioBufferList *inInputData,
                                                                                                 const AudioTimeStamp *inInputTime,
                                                                                                 AudioBufferList *outOutputData,
                                                                                                 const AudioTimeStamp *inOutputTime) {
        (void)inNow;
        (void)inInputTime;
        (void)inOutputTime;
        UInt32 frames = separateOutput ? 0 : framesInBufferList(outOutputData);
        if (frames == 0) frames = framesInBufferList(inInputData);
        if (frames == 0) frames = (UInt32)unsafeSelf->_bufferFrameSize;
        [unsafeSelf renderInput:inInputData output:(separateOutput ? nullptr : outOutputData) frames:frames];
    });
    if (status != noErr) {
        [self stop];
        [self fail:error message:[NSString stringWithFormat:@"AudioDeviceCreateIOProcIDWithBlock failed (%d).", status]];
        return NO;
    }
    if (separateOutput) {
        status = AudioDeviceCreateIOProcIDWithBlock(&_outputIOProcID, outputDevice, _outputAudioQueue, ^(const AudioTimeStamp *inNow,
                                                                                                          const AudioBufferList *inInputData,
                                                                                                          const AudioTimeStamp *inInputTime,
                                                                                                          AudioBufferList *outOutputData,
                                                                                                          const AudioTimeStamp *inOutputTime) {
            (void)inNow;
            (void)inInputData;
            (void)inInputTime;
            (void)inOutputTime;
            UInt32 frames = framesInBufferList(outOutputData);
            if (frames == 0) frames = (UInt32)outputBufferFrames;
            [unsafeSelf renderSeparateOutput:outOutputData frames:frames];
        });
        if (status != noErr) {
            [self stop];
            [self fail:error message:[NSString stringWithFormat:@"Output AudioDeviceCreateIOProcIDWithBlock failed (%d).", status]];
            return NO;
        }
    }

    _runningAtomic.store(true);
    status = AudioDeviceStart(inputDevice, _ioProcID);
    if (status != noErr) {
        [self stop];
        [self fail:error message:[NSString stringWithFormat:@"Input AudioDeviceStart failed (%d).", status]];
        return NO;
    }
    if (separateOutput) {
        status = AudioDeviceStart(outputDevice, _outputIOProcID);
        if (status != noErr) {
            [self stop];
            [self fail:error message:[NSString stringWithFormat:@"Output AudioDeviceStart failed (%d).", status]];
            return NO;
        }
    }

    NSString *outputStatus = separateOutput ? @"separate stream output" : @"same-device output";
    [self setStatus:[NSString stringWithFormat:@"HD96/Dante 96 kHz ready - %ld input ch @ %.0f Hz - %@", (long)_inputChannelCount, sampleRate, outputStatus]];
    return YES;
}

- (BOOL)startSimulatedWithChannelCount:(NSInteger)channelCount
                            sampleRate:(double)sampleRate
                       bufferFrameSize:(NSInteger)bufferFrameSize
                           channelRoles:(NSArray<NSString *> *)roles
                    inputChannelIndices:(NSArray<NSNumber *> *)inputChannelIndices
                                  error:(NSError **)error {
    if (_runningAtomic.load()) [self stop];

    _deviceID = kAudioObjectUnknown;
    _ioProcID = nullptr;
    _outputDeviceID = kAudioObjectUnknown;
    _outputIOProcID = nullptr;
    _simulationMode = true;
    _separateOutputMode = false;
    _simulationFrame = 0;
    [self resetRealtimeCounters];
    const NSInteger channels = channelCount > 0 ? channelCount : 64;
    const double rate = sampleRate > 0 ? sampleRate : 96000.0;
    const NSInteger frames = bufferFrameSize > 0 ? bufferFrameSize : 256;

    if (![self prepareEngineWithInputChannels:channels
                               outputChannels:2
                                   sampleRate:rate
                              bufferFrameSize:frames
                                 channelRoles:roles
                          inputChannelIndices:inputChannelIndices
                                        error:error]) {
        return NO;
    }

    __unsafe_unretained AutoMixEngineBridge *unsafeSelf = self;
    _simulationTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _audioQueue);
    const uint64_t intervalNs = (uint64_t)std::max<double>(1000000.0, std::round((double)frames / rate * 1000000000.0));
    dispatch_source_set_timer(_simulationTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 4);
    dispatch_source_set_event_handler(_simulationTimer, ^{
        [unsafeSelf renderSimulatedFrames:(UInt32)unsafeSelf->_bufferFrameSize];
    });

    _runningAtomic.store(true);
    dispatch_resume(_simulationTimer);
    [self setStatus:[NSString stringWithFormat:@"Simulated HD96/Dante - %ld input ch @ %.0f Hz", (long)_inputChannelCount, rate]];
    return YES;
}

- (BOOL)startSimulatedSeparateOutputWithChannelCount:(NSInteger)channelCount
                                         sampleRate:(double)sampleRate
                              inputBufferFrameSize:(NSInteger)inputBufferFrameSize
                             outputBufferFrameSize:(NSInteger)outputBufferFrameSize
                                      channelRoles:(NSArray<NSString *> *)roles
                               inputChannelIndices:(NSArray<NSNumber *> *)inputChannelIndices
                                             error:(NSError **)error {
    if (_runningAtomic.load()) [self stop];

    _deviceID = kAudioObjectUnknown;
    _ioProcID = nullptr;
    _outputDeviceID = kAudioObjectUnknown;
    _outputIOProcID = nullptr;
    _simulationMode = true;
    _separateOutputMode = true;
    _simulationFrame = 0;
    [self resetRealtimeCounters];
    const NSInteger channels = channelCount > 0 ? channelCount : 64;
    const double rate = sampleRate > 0 ? sampleRate : 96000.0;
    const NSInteger inputFrames = inputBufferFrameSize > 0 ? inputBufferFrameSize : 256;
    const NSInteger outputFrames = outputBufferFrameSize > 0 ? outputBufferFrameSize : inputFrames;

    if (![self prepareEngineWithInputChannels:channels
                               outputChannels:2
                                   sampleRate:rate
                              bufferFrameSize:inputFrames
                                 channelRoles:roles
                          inputChannelIndices:inputChannelIndices
                                        error:error]) {
        return NO;
    }
    [self prepareSeparateOutputRingWithSampleRate:rate
                                inputBufferFrames:inputFrames
                               outputBufferFrames:outputFrames];

    __unsafe_unretained AutoMixEngineBridge *unsafeSelf = self;
    _simulationTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _audioQueue);
    const uint64_t inputIntervalNs = (uint64_t)std::max<double>(1000000.0, std::round((double)inputFrames / rate * 1000000000.0));
    dispatch_source_set_timer(_simulationTimer, dispatch_time(DISPATCH_TIME_NOW, 0), inputIntervalNs, inputIntervalNs / 4);
    dispatch_source_set_event_handler(_simulationTimer, ^{
        [unsafeSelf renderSimulatedFrames:(UInt32)unsafeSelf->_bufferFrameSize];
    });

    _simulationOutputTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _outputAudioQueue);
    const uint64_t outputIntervalNs = (uint64_t)std::max<double>(1000000.0, std::round((double)outputFrames / rate * 1000000000.0));
    const uint64_t primingFrames = _outputRingWriteFrameAtomic.load(std::memory_order_acquire);
    const uint64_t outputStartDelayNs = (uint64_t)std::max<double>((double)outputIntervalNs,
                                                                    std::round((double)primingFrames / rate * 1000000000.0));
    dispatch_source_set_timer(_simulationOutputTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)outputStartDelayNs),
                              outputIntervalNs,
                              outputIntervalNs / 4);
    dispatch_source_set_event_handler(_simulationOutputTimer, ^{
        [unsafeSelf renderSeparateOutput:nullptr frames:(UInt32)outputFrames];
    });

    _runningAtomic.store(true);
    dispatch_resume(_simulationTimer);
    dispatch_resume(_simulationOutputTimer);
    [self setStatus:[NSString stringWithFormat:@"Simulated HD96/Dante separate output - %ld input ch @ %.0f Hz", (long)_inputChannelCount, rate]];
    return YES;
}

- (void)stop {
    _runningAtomic.store(false);
    _recordingAtomic.store(false);
    if (_simulationTimer) {
        dispatch_source_cancel(_simulationTimer);
        _simulationTimer = nullptr;
    }
    if (_simulationOutputTimer) {
        dispatch_source_cancel(_simulationOutputTimer);
        _simulationOutputTimer = nullptr;
    }
    if (_outputDeviceID != kAudioObjectUnknown && _outputIOProcID != nullptr) {
        AudioDeviceStop(_outputDeviceID, _outputIOProcID);
        AudioDeviceDestroyIOProcID(_outputDeviceID, _outputIOProcID);
    }
    if (_deviceID != kAudioObjectUnknown && _ioProcID != nullptr) {
        AudioDeviceStop(_deviceID, _ioProcID);
        AudioDeviceDestroyIOProcID(_deviceID, _ioProcID);
    }
    if (_audioQueue && dispatch_get_specific(&AMAudioQueueSpecificKey) == nullptr) {
        dispatch_sync(_audioQueue, ^{});
    }
    if (_outputAudioQueue && dispatch_get_specific(&AMOutputAudioQueueSpecificKey) == nullptr) {
        dispatch_sync(_outputAudioQueue, ^{});
    }
    _ioProcID = nullptr;
    _outputIOProcID = nullptr;
    _deviceID = kAudioObjectUnknown;
    _outputDeviceID = kAudioObjectUnknown;
    _simulationMode = false;
    _separateOutputMode = false;
    if (_brainStarted) {
        _brain.stop();
        _brainStarted = false;
    }
    // Reset meters so a stopped engine reads silence instead of freezing the last
    // sample on screen (which looks like a live-but-stuck meter).
    if (_meterDb) {
        for (NSInteger i = 0; i < _inputChannelCount; ++i) {
            _meterDb[(size_t)i].store(-100.0f, std::memory_order_relaxed);
        }
    }
    _outputMeterDbL.store(-100.0f, std::memory_order_relaxed);
    _outputMeterDbR.store(-100.0f, std::memory_order_relaxed);
    _momentaryLufsAtomic.store(-100.0f, std::memory_order_relaxed);
    _shortTermLufsAtomic.store(-100.0f, std::memory_order_relaxed);
    _integratedLufsAtomic.store(-100.0f, std::memory_order_relaxed);
    _limiterGainReductionDbAtomic.store(0.0f, std::memory_order_relaxed);
    [self setStatus:@"Stopped"];
}

- (void)setSafeBypass:(BOOL)enabled {
    _safeBypassAtomic.store(enabled);
    _brain.setOperatorBypass(enabled);
}

- (void)setFrozen:(BOOL)enabled {
    _frozenAtomic.store(enabled);
    _brain.setFrozen(enabled);
}

- (void)setShadowMode:(BOOL)enabled {
    _shadowModeAtomic.store(enabled, std::memory_order_relaxed);
    _brain.setShadowMode(enabled);
}

- (void)setSceneName:(NSString *)sceneName {
    _scene = sceneForName(sceneName);
    _brain.setScene(_scene);
}

- (BOOL)setChannelRoleForChannel:(NSInteger)channel
                             role:(NSString *)role {
    if (channel < 0 || channel >= _inputChannelCount || channel >= app::EngineSnapshot::kMaxCh) return NO;
    const app::Cls assignedClass = classForRole(role);
    _classes[(size_t)channel] = assignedClass;
    _pendingClassCodes[(size_t)channel].store((int)assignedClass, std::memory_order_release);
    _roleConfigDirtyAtomic.store(true, std::memory_order_release);
    if (_brainStarted) return _brain.setAssignedClass((int)channel, assignedClass);
    return YES;
}

- (BOOL)setInputChannelIndex:(NSInteger)inputChannelIndex
             forMixerChannel:(NSInteger)mixerChannel {
    if (mixerChannel < 0 || mixerChannel >= _inputChannelCount || mixerChannel >= app::EngineSnapshot::kMaxCh) return NO;
    if (inputChannelIndex < 0 || inputChannelIndex >= _inputChannelCount) return NO;
    _inputChannelIndices[(size_t)mixerChannel].store((int)inputChannelIndex, std::memory_order_release);
    return YES;
}

- (BOOL)setManualMixOverrideForChannel:(NSInteger)channel
                               faderDb:(double)faderDb
                                    pan:(double)pan
                          overrideFader:(BOOL)overrideFader
                            overridePan:(BOOL)overridePan {
    bdsp::ChannelParams params;
    params.faderDb = (float)std::max(-80.0, std::min(12.0, faderDb));
    params.pan = (float)std::max(-1.0, std::min(1.0, pan));
    app::OverrideMask mask = 0;
    if (overrideFader) mask |= app::OverrideFader;
    if (overridePan) mask |= app::OverridePan;
    if (mask == 0) return [self clearManualMixOverrideForChannel:channel];
    return _brain.setManualChannelParams((int)channel, params, mask);
}

- (BOOL)clearManualMixOverrideForChannel:(NSInteger)channel {
    return _brain.clearManualOverrides((int)channel, app::OverrideFader | app::OverridePan);
}

- (NSArray<NSNumber *> *)inputLevelsDb {
    [self scheduleFinishedRecordingWriteIfNeeded];
    [self refreshStatusFromRealtimeCounters];
    NSMutableArray<NSNumber *> *levels = [NSMutableArray arrayWithCapacity:_inputChannelCount];
    for (NSInteger i = 0; i < _inputChannelCount; ++i) {
        [levels addObject:@(_meterDb ? _meterDb[(size_t)i].load() : -100.0f)];
    }
    return levels;
}

- (NSArray<NSNumber *> *)outputLevelsDb {
    return @[
        @(_outputMeterDbL.load(std::memory_order_relaxed)),
        @(_outputMeterDbR.load(std::memory_order_relaxed))
    ];
}

- (BOOL)startTestRecordingAtURL:(NSURL *)url
                        seconds:(double)seconds
                          error:(NSError **)error {
    if (!_runningAtomic.load()) {
        [self fail:error message:@"Start the audio engine before recording a Dante test."];
        return NO;
    }
    if (_recordingAtomic.load()) {
        [self fail:error message:@"A test recording is already running."];
        return NO;
    }
    if (_recordWriteInFlightAtomic.load(std::memory_order_acquire) ||
        _recordWriteScheduledAtomic.load(std::memory_order_acquire) ||
        _recordReadyToWrite.load(std::memory_order_acquire)) {
        [self fail:error message:@"A Dante test recording is still being saved."];
        return NO;
    }

    const double safeSeconds = std::max(1.0, std::min(seconds, 30.0));
    _recordChannels = (int)_inputChannelCount + 2;
    _recordFrameCapacity = (uint64_t)std::ceil(_sampleRate * safeSeconds);
    _recordFrameWrite = 0;
    _recordFrameCapacityAtomic.store(_recordFrameCapacity, std::memory_order_relaxed);
    _recordFrameWriteAtomic.store(0, std::memory_order_relaxed);
    _recordBuffer.assign((size_t)(_recordFrameCapacity * (uint64_t)_recordChannels), 0.0f);
    _recordURL = url;
    @synchronized (self) {
        _finishedRecordingURL = nil;
    }
    _recordWriteScheduledAtomic.store(false, std::memory_order_release);
    _recordReadyToWrite.store(false);
    _recordingAtomic.store(true);
    [self setStatus:[NSString stringWithFormat:@"Recording %.0fs Dante test with stereo stream mix...", safeSeconds]];
    return YES;
}

- (NSURL *)consumeFinishedRecordingURL {
    [self scheduleFinishedRecordingWriteIfNeeded];
    NSURL *url = nil;
    @synchronized (self) {
        url = _finishedRecordingURL;
        _finishedRecordingURL = nil;
    }
    return url;
}

- (void)renderInput:(const AudioBufferList *)input output:(AudioBufferList *)output frames:(UInt32)frames {
    if (!_runningAtomic.load()) {
        [self clearOutputBufferList:output];
        return;
    }
    const uint64_t startTicks = mach_absolute_time();
    [self noteCallbackFrames:frames];
    if (frames > (UInt32)_bufferFrameSize) {
        _dropoutCountAtomic.fetch_add(1, std::memory_order_relaxed);
        _callbackOverrunCountAtomic.fetch_add(1, std::memory_order_relaxed);
        [self clearOutputBufferList:output];
        return;
    }
    const UInt32 safeFrames = frames;
    const int chCount = (int)_inputChannelCount;
    if (![self renderStateIsPreparedForFrames:safeFrames channelCount:chCount]) {
        _dropoutCountAtomic.fetch_add(1, std::memory_order_relaxed);
        [self clearOutputBufferList:output];
        return;
    }

    [self fillInputPointersFromBufferList:input frames:safeFrames];

    [self processCurrentInputFrames:safeFrames output:output];
    [self noteRenderDurationFromStartTicks:startTicks frames:safeFrames];
}

- (void)renderSimulatedFrames:(UInt32)frames {
    if (!_runningAtomic.load()) return;
    const uint64_t startTicks = mach_absolute_time();
    [self noteCallbackFrames:frames];
    const int chCount = (int)_inputChannelCount;
    const UInt32 safeFrames = std::min<UInt32>(frames, (UInt32)_bufferFrameSize);
    if (![self renderStateIsPreparedForFrames:safeFrames channelCount:chCount]) {
        _dropoutCountAtomic.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    const double twoPi = 6.28318530717958647692;

    for (int ch = 0; ch < chCount; ++ch) {
        float *dst = _inputScratch[(size_t)ch].data();
        _rawInputPtrs[(size_t)ch] = dst;
        const double freq = 120.0 + 37.0 * (double)(ch % 24);
        const float amp = 0.008f + 0.004f * (float)((ch % 8) + 1);
        for (UInt32 s = 0; s < safeFrames; ++s) {
            const double t = (double)(_simulationFrame + s) / _sampleRate;
            const double mod = 0.65 + 0.35 * std::sin(twoPi * 0.21 * t + (double)ch * 0.13);
            dst[s] = amp * (float)mod * (float)std::sin(twoPi * freq * t);
        }
    }
    [self applyInputChannelMapPointers];
    _simulationFrame += safeFrames;
    [self processCurrentInputFrames:safeFrames output:nullptr];
    [self noteRenderDurationFromStartTicks:startTicks frames:safeFrames];
}

- (void)processCurrentInputFrames:(UInt32)safeFrames output:(AudioBufferList *)output {
    const int chCount = (int)_inputChannelCount;
    if (![self renderStateIsPreparedForFrames:safeFrames channelCount:chCount]) {
        _dropoutCountAtomic.fetch_add(1, std::memory_order_relaxed);
        [self clearOutputBufferList:output];
        return;
    }

    for (int ch = 0; ch < chCount; ++ch) {
        const float *src = _inputPtrs[(size_t)ch] ? _inputPtrs[(size_t)ch] : _silence.data();
        double sum = 0.0;
        float peak = 0.0f;
        for (UInt32 s = 0; s < safeFrames; ++s) {
            sum += (double)src[s] * src[s];
            peak = std::max(peak, std::fabs(src[s]));
        }
        const double rms = std::sqrt(sum / std::max<UInt32>(1, safeFrames));
        const float db = rms > 1e-7 ? (float)(20.0 * std::log10(rms)) : -100.0f;
        _meterDb[(size_t)ch].store(db);
        const float peakDb = peak > 1e-7f ? 20.0f * std::log10(peak) : -100.0f;
        _brain.pushChannelMeasurement(ch, db, peakDb, _engine.channelPostRmsDb(ch));
    }

    [self applyPendingRoleConfigIfNeeded];
    _brain.pushMasterMeasurement(
        _engine.shortTermLufs(),
        _engine.momentaryLufs(),
        _engine.limiterGrDb(),
        _engine.shortTermLoudnessReady()
    );
    _brain.applyTo(_engine);
    _engine.setBypass(_safeBypassAtomic.load(std::memory_order_relaxed) ||
                      _brain.watchdogBypassActive());
    _engine.process(_inputPtrs.data(), chCount, _outL.data(), _outR.data(), (int)safeFrames);
    [self updateOutputMetersForFrames:safeFrames];
    [self updateMasterTelemetry];
    if (_recordingAtomic.load()) [self captureRecordingFrames:safeFrames];
    if (_separateOutputMode) [self writeSeparateOutputRingFrames:safeFrames];
    [self writeOutputBufferList:output frames:safeFrames];
}

- (BOOL)renderStateIsPreparedForFrames:(UInt32)frames channelCount:(int)chCount {
    if (frames == 0 || chCount <= 0 || _bufferFrameSize <= 0 || _sampleRate <= 0 || !_meterDb) {
        return NO;
    }
    if (frames > (UInt32)_bufferFrameSize) return NO;
    const size_t channels = (size_t)chCount;
    const size_t frameCount = (size_t)frames;
    return _inputScratch.size() >= channels &&
        _rawInputPtrs.size() >= channels &&
        _inputPtrs.size() >= channels &&
        _outL.size() >= frameCount &&
        _outR.size() >= frameCount &&
        _silence.size() >= frameCount;
}

- (void)updateOutputMetersForFrames:(UInt32)frames {
    double sumL = 0.0;
    double sumR = 0.0;
    for (UInt32 s = 0; s < frames; ++s) {
        const double left = (double)_outL[(size_t)s];
        const double right = (double)_outR[(size_t)s];
        sumL += left * left;
        sumR += right * right;
    }
    const double denom = (double)std::max<UInt32>(1, frames);
    const double rmsL = std::sqrt(sumL / denom);
    const double rmsR = std::sqrt(sumR / denom);
    _outputMeterDbL.store(rmsL > 1e-7 ? (float)(20.0 * std::log10(rmsL)) : -100.0f, std::memory_order_relaxed);
    _outputMeterDbR.store(rmsR > 1e-7 ? (float)(20.0 * std::log10(rmsR)) : -100.0f, std::memory_order_relaxed);
}

- (void)updateMasterTelemetry {
    _momentaryLufsAtomic.store(_engine.momentaryLufs(), std::memory_order_relaxed);
    _shortTermLufsAtomic.store(_engine.shortTermLufs(), std::memory_order_relaxed);
    _integratedLufsAtomic.store(_engine.integratedLufs(), std::memory_order_relaxed);
    _limiterGainReductionDbAtomic.store(_engine.limiterGrDb(), std::memory_order_relaxed);
}

- (void)prepareSeparateOutputRingWithSampleRate:(double)sampleRate
                              inputBufferFrames:(NSInteger)inputFrames
                             outputBufferFrames:(NSInteger)outputFrames {
    const uint64_t halfSecond = (uint64_t)std::ceil(std::max(1.0, sampleRate) * 0.5);
    const uint64_t blockFloor = (uint64_t)std::max<NSInteger>(inputFrames, outputFrames) * 32u;
    _outputRingFrameCapacity = std::max<uint64_t>(halfSecond, blockFloor);
    _outputRingL.assign((size_t)_outputRingFrameCapacity, 0.0f);
    _outputRingR.assign((size_t)_outputRingFrameCapacity, 0.0f);
    const uint64_t prebuffer = std::min<uint64_t>(_outputRingFrameCapacity / 2u,
                                                  (uint64_t)std::max<NSInteger>(inputFrames, outputFrames) * 16u);
    _outputRingReadFrameAtomic.store(0, std::memory_order_release);
    _outputRingWriteFrameAtomic.store(prebuffer, std::memory_order_release);
}

- (void)writeSeparateOutputRingFrames:(UInt32)frames {
    if (_outputRingFrameCapacity == 0 || _outputRingL.empty() || _outputRingR.empty()) return;
    uint64_t readFrame = _outputRingReadFrameAtomic.load(std::memory_order_acquire);
    const uint64_t writeFrame = _outputRingWriteFrameAtomic.load(std::memory_order_relaxed);
    if (writeFrame + frames - readFrame > _outputRingFrameCapacity) {
        readFrame = writeFrame + frames - _outputRingFrameCapacity;
        _outputRingReadFrameAtomic.store(readFrame, std::memory_order_release);
        if (!_simulationMode) {
            _dropoutCountAtomic.fetch_add(1, std::memory_order_relaxed);
            _outputOverrunCountAtomic.fetch_add(1, std::memory_order_relaxed);
        }
    }

    for (UInt32 s = 0; s < frames; ++s) {
        const size_t index = (size_t)((writeFrame + s) % _outputRingFrameCapacity);
        _outputRingL[index] = _outL[s];
        _outputRingR[index] = _outR[s];
    }
    _outputRingWriteFrameAtomic.store(writeFrame + frames, std::memory_order_release);
}

- (void)renderSeparateOutput:(AudioBufferList *)output frames:(UInt32)frames {
    if (!_runningAtomic.load()) {
        [self clearOutputBufferList:output];
        return;
    }
    if (_outputRingFrameCapacity == 0 || _outputRingL.empty() || _outputRingR.empty()) {
        [self clearOutputBufferList:output];
        if (!_simulationMode) {
            _dropoutCountAtomic.fetch_add(1, std::memory_order_relaxed);
            _outputUnderrunCountAtomic.fetch_add(1, std::memory_order_relaxed);
        }
        return;
    }

    uint64_t readFrame = _outputRingReadFrameAtomic.load(std::memory_order_relaxed);
    const uint64_t writeFrame = _outputRingWriteFrameAtomic.load(std::memory_order_acquire);
    const uint64_t available = writeFrame > readFrame ? writeFrame - readFrame : 0;
    const UInt32 framesToRead = (UInt32)std::min<uint64_t>(frames, available);

    [self writeSeparateOutputBufferList:output readFrame:readFrame frames:frames framesToRead:framesToRead];
    _outputRingReadFrameAtomic.store(readFrame + framesToRead, std::memory_order_release);

    if (framesToRead < frames) {
        if (!_simulationMode) {
            _dropoutCountAtomic.fetch_add(1, std::memory_order_relaxed);
            _outputUnderrunCountAtomic.fetch_add(1, std::memory_order_relaxed);
        }
    }
}

- (void)writeSeparateOutputBufferList:(AudioBufferList *)output
                            readFrame:(uint64_t)readFrame
                                frames:(UInt32)frames
                          framesToRead:(UInt32)framesToRead {
    if (!output) return;
    if (output->mNumberBuffers >= 2 &&
        output->mBuffers[0].mNumberChannels == 1 &&
        output->mBuffers[1].mNumberChannels == 1) {
        float *left = (float *)output->mBuffers[0].mData;
        float *right = (float *)output->mBuffers[1].mData;
        for (UInt32 s = 0; s < frames; ++s) {
            if (s < framesToRead) {
                const size_t index = (size_t)((readFrame + s) % _outputRingFrameCapacity);
                left[s] = _outputRingL[index];
                right[s] = _outputRingR[index];
            } else {
                left[s] = 0.0f;
                right[s] = 0.0f;
            }
        }
        for (UInt32 b = 2; b < output->mNumberBuffers; ++b) {
            AudioBuffer &buffer = output->mBuffers[b];
            if (buffer.mData) std::memset(buffer.mData, 0, buffer.mDataByteSize);
        }
        return;
    }

    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
        AudioBuffer &buffer = output->mBuffers[b];
        if (!buffer.mData) continue;
        const UInt32 channels = std::max<UInt32>(1, buffer.mNumberChannels);
        float *data = (float *)buffer.mData;
        for (UInt32 s = 0; s < frames; ++s) {
            float left = 0.0f;
            float right = 0.0f;
            if (s < framesToRead) {
                const size_t index = (size_t)((readFrame + s) % _outputRingFrameCapacity);
                left = _outputRingL[index];
                right = _outputRingR[index];
            }
            for (UInt32 c = 0; c < channels; ++c) {
                data[(size_t)s * channels + c] = c == 0 ? left : (c == 1 ? right : 0.0f);
            }
        }
    }
}

- (void)applyPendingRoleConfigIfNeeded {
    if (!_roleConfigDirtyAtomic.exchange(false, std::memory_order_acq_rel)) return;
    const int count = (int)std::min<NSInteger>(_inputChannelCount, app::EngineSnapshot::kMaxCh);
    for (int i = 0; i < count; ++i) {
        const auto assignedClass = (app::Cls)_pendingClassCodes[(size_t)i].load(std::memory_order_acquire);
        const auto profile = app::profileFor(assignedClass);
        _engine.setChannelConfig(
            i,
            profile.bus,
            profile.isSpeech,
            app::safeGainDbFor(assignedClass),
            app::safePanFor(assignedClass)
        );
    }
}

- (void)clearOutputBufferList:(AudioBufferList *)output {
    clearAudioBufferList(output);
}

- (void)fillInputPointersFromBufferList:(const AudioBufferList *)input frames:(UInt32)frames {
    const int chCount = (int)_inputChannelCount;
    populateRawInputPointersFromBufferList(input,
                                           frames,
                                           chCount,
                                           _inputScratch,
                                           _rawInputPtrs,
                                           _silence.data());
    [self applyInputChannelMapPointers];
}

- (void)applyInputChannelMapPointers {
    const int chCount = (int)_inputChannelCount;
    for (int mixerChannel = 0; mixerChannel < chCount; ++mixerChannel) {
        const int inputChannel = _inputChannelIndices[(size_t)mixerChannel].load(std::memory_order_acquire);
        const bool valid = inputChannel >= 0 && inputChannel < chCount && (size_t)inputChannel < _rawInputPtrs.size();
        const float *src = valid && _rawInputPtrs[(size_t)inputChannel] ? _rawInputPtrs[(size_t)inputChannel] : _silence.data();
        _inputPtrs[(size_t)mixerChannel] = src;
    }
}

- (void)writeOutputBufferList:(AudioBufferList *)output frames:(UInt32)frames {
    if (!output) return;
    if (output->mNumberBuffers >= 2 &&
        output->mBuffers[0].mNumberChannels == 1 &&
        output->mBuffers[1].mNumberChannels == 1) {
        std::memcpy(output->mBuffers[0].mData, _outL.data(), sizeof(float) * frames);
        std::memcpy(output->mBuffers[1].mData, _outR.data(), sizeof(float) * frames);
        for (UInt32 b = 2; b < output->mNumberBuffers; ++b) {
            AudioBuffer &buffer = output->mBuffers[b];
            if (buffer.mData) std::memset(buffer.mData, 0, buffer.mDataByteSize);
        }
        return;
    }

    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
        AudioBuffer &buffer = output->mBuffers[b];
        if (!buffer.mData) continue;
        const UInt32 channels = std::max<UInt32>(1, buffer.mNumberChannels);
        float *data = (float *)buffer.mData;
        for (UInt32 s = 0; s < frames; ++s) {
            for (UInt32 c = 0; c < channels; ++c) {
                data[(size_t)s * channels + c] = c == 0 ? _outL[s] : (c == 1 ? _outR[s] : 0.0f);
            }
        }
    }
}

- (void)noteCallbackFrames:(UInt32)frames {
    _lastCallbackFramesAtomic.store(frames, std::memory_order_relaxed);
    uint32_t previous = _maxObservedCallbackFramesAtomic.load(std::memory_order_relaxed);
    while (frames > previous &&
           !_maxObservedCallbackFramesAtomic.compare_exchange_weak(previous, frames, std::memory_order_relaxed)) {
    }
}

- (void)noteRenderDurationFromStartTicks:(uint64_t)startTicks frames:(UInt32)frames {
    if (_simulationMode) return;
    if (_sampleRate <= 0 || frames == 0) return;
    const uint64_t elapsedTicks = mach_absolute_time() - startTicks;
    const double elapsedNs = (double)elapsedTicks * (double)_machTimeNumer / (double)_machTimeDenom;
    const double budgetNs = (double)frames / _sampleRate * 1000000000.0;
    if (elapsedNs > budgetNs * 0.85) {
        _dropoutCountAtomic.fetch_add(1, std::memory_order_relaxed);
        _deadlineMissCountAtomic.fetch_add(1, std::memory_order_relaxed);
    }
}

- (void)resetRealtimeCounters {
    _dropoutCountAtomic.store(0, std::memory_order_relaxed);
    _callbackOverrunCountAtomic.store(0, std::memory_order_relaxed);
    _deadlineMissCountAtomic.store(0, std::memory_order_relaxed);
    _outputUnderrunCountAtomic.store(0, std::memory_order_relaxed);
    _outputOverrunCountAtomic.store(0, std::memory_order_relaxed);
    _outputRingReadFrameAtomic.store(0, std::memory_order_relaxed);
    _outputRingWriteFrameAtomic.store(0, std::memory_order_relaxed);
    _lastCallbackFramesAtomic.store(0, std::memory_order_relaxed);
    _maxObservedCallbackFramesAtomic.store(0, std::memory_order_relaxed);
    _outputMeterDbL.store(-100.0f, std::memory_order_relaxed);
    _outputMeterDbR.store(-100.0f, std::memory_order_relaxed);
    _momentaryLufsAtomic.store(-100.0f, std::memory_order_relaxed);
    _shortTermLufsAtomic.store(-100.0f, std::memory_order_relaxed);
    _integratedLufsAtomic.store(-100.0f, std::memory_order_relaxed);
    _limiterGainReductionDbAtomic.store(0.0f, std::memory_order_relaxed);
}

- (void)captureRecordingFrames:(UInt32)frames {
    const int channels = _recordChannels;
    if (channels < 2 || _recordBuffer.empty()) {
        _recordingAtomic.store(false);
        _recordReadyToWrite.store(true);
        return;
    }

    const uint64_t availableFrames = (uint64_t)(_recordBuffer.size() / (size_t)channels);
    const uint64_t targetFrames = std::min(_recordFrameCapacity, availableFrames);
    if (targetFrames == 0 || _recordFrameWrite >= targetFrames) {
        _recordingAtomic.store(false);
        _recordReadyToWrite.store(true);
        return;
    }

    const uint64_t framesToCopy = std::min<uint64_t>(frames, targetFrames - _recordFrameWrite);
    const int inputRecordChannels = std::max(0, std::min<int>((int)_inputChannelCount, channels - 2));
    for (uint64_t s = 0; s < framesToCopy; ++s) {
        const size_t base = (size_t)((_recordFrameWrite + s) * (uint64_t)channels);
        for (int ch = 0; ch < inputRecordChannels; ++ch) {
            const bool valid = (size_t)ch < _rawInputPtrs.size() && _rawInputPtrs[(size_t)ch] != nullptr;
            const float *src = valid ? _rawInputPtrs[(size_t)ch] : _silence.data();
            _recordBuffer[base + (size_t)ch] = src[s];
        }
        const size_t frameIndex = (size_t)s;
        const float outL = frameIndex < _outL.size() ? _outL[frameIndex] : 0.0f;
        const float outR = frameIndex < _outR.size() ? _outR[frameIndex] : 0.0f;
        _recordBuffer[base + (size_t)inputRecordChannels] = outL;
        _recordBuffer[base + (size_t)inputRecordChannels + 1u] = outR;
    }
    _recordFrameWrite += framesToCopy;
    _recordFrameWriteAtomic.store(_recordFrameWrite, std::memory_order_relaxed);
    if (_recordFrameWrite >= targetFrames) {
        _recordingAtomic.store(false);
        _recordReadyToWrite.store(true);
    }
}

- (void)scheduleFinishedRecordingWriteIfNeeded {
    if (_recordWriteInFlightAtomic.load(std::memory_order_acquire)) return;
    if (!_recordReadyToWrite.load(std::memory_order_acquire)) return;
    if (_recordWriteScheduledAtomic.exchange(true, std::memory_order_acq_rel)) return;

    AutoMixEngineBridge *strongSelf = self;
    dispatch_async(_fileQueue, ^{
        [strongSelf writeFinishedRecordingOnFileQueue];
    });
}

- (void)writeFinishedRecordingOnFileQueue {
    if (!_recordReadyToWrite.exchange(false, std::memory_order_acq_rel)) {
        _recordWriteScheduledAtomic.store(false, std::memory_order_release);
        return;
    }
    if (_recordWriteInFlightAtomic.exchange(true, std::memory_order_acq_rel)) {
        _recordReadyToWrite.store(true, std::memory_order_release);
        _recordWriteScheduledAtomic.store(false, std::memory_order_release);
        return;
    }

    NSURL *url = _recordURL;
    const int channels = _recordChannels;
    const uint64_t availableFrames = channels > 0 ? (uint64_t)(_recordBuffer.size() / (size_t)channels) : 0;
    const uint64_t frames = std::min(_recordFrameWrite, availableFrames);
    const uint32_t sampleRate = (uint32_t)_sampleRate;
    if (!url || frames == 0 || channels <= 0 || sampleRate == 0 || availableFrames < _recordFrameWrite) {
        _recordWriteInFlightAtomic.store(false, std::memory_order_release);
        _recordWriteScheduledAtomic.store(false, std::memory_order_release);
        [self setStatus:@"Failed to save multichannel test: incomplete recording buffer."];
        return;
    }

    std::vector<float> samples;
    samples.swap(_recordBuffer);
    _recordWriteScheduledAtomic.store(false, std::memory_order_release);

    [self setStatus:[NSString stringWithFormat:@"Saving multichannel test: %@", url.lastPathComponent]];
    const uint64_t expectedSamples = frames * (uint64_t)channels;
    if ((uint64_t)samples.size() < expectedSamples) {
        [self setStatus:@"Failed to write multichannel test recording: incomplete sample buffer."];
        _recordWriteInFlightAtomic.store(false, std::memory_order_release);
        return;
    }
    const bool ok = writeFloatWav(url.path.UTF8String, samples.data(), frames, channels, sampleRate);
    if (ok) {
        @synchronized (self) {
            _finishedRecordingURL = url;
        }
        [self setStatus:[NSString stringWithFormat:@"Saved multichannel test: %@", url.lastPathComponent]];
    } else {
        [self setStatus:@"Failed to write multichannel test recording."];
    }
    _recordWriteInFlightAtomic.store(false, std::memory_order_release);
}

- (BOOL)prepareEngineWithInputChannels:(NSInteger)inputChannels
                         outputChannels:(NSInteger)outputChannels
                             sampleRate:(double)sampleRate
                        bufferFrameSize:(NSInteger)bufferFrames
                           channelRoles:(NSArray<NSString *> *)roles
                    inputChannelIndices:(NSArray<NSNumber *> *)inputChannelIndices
                                  error:(NSError **)error {
    if (_brainStarted) {
        _brain.stop();
        _brainStarted = false;
    }

    const int engineChannels = (int)std::min<NSInteger>(std::max<NSInteger>(inputChannels, 1), app::EngineSnapshot::kMaxCh);
    const int maxBlock = (int)std::max<NSInteger>(bufferFrames, 1);
    _inputChannelCount = engineChannels;
    _outputChannelCount = outputChannels;
    _sampleRate = sampleRate;
    _bufferFrameSize = maxBlock;
    _classes = [self classesFromRoles:roles count:engineChannels];
    for (int i = 0; i < app::EngineSnapshot::kMaxCh; ++i) {
        const app::Cls assignedClass = i < engineChannels ? _classes[(size_t)i] : app::Cls::Unknown;
        _pendingClassCodes[(size_t)i].store((int)assignedClass, std::memory_order_release);
        const int defaultInput = std::min(i, std::max(engineChannels - 1, 0));
        int mappedInput = defaultInput;
        if (i < engineChannels && i < (int)inputChannelIndices.count) {
            mappedInput = (int)inputChannelIndices[(NSUInteger)i].integerValue;
        }
        mappedInput = std::max(0, std::min(mappedInput, std::max(engineChannels - 1, 0)));
        _inputChannelIndices[(size_t)i].store(mappedInput, std::memory_order_release);
    }
    _roleConfigDirtyAtomic.store(false, std::memory_order_release);
    _inputScratch.assign(engineChannels, std::vector<float>(maxBlock, 0.0f));
    _rawInputPtrs.assign(engineChannels, nullptr);
    _inputPtrs.assign(engineChannels, nullptr);
    _outL.assign(maxBlock, 0.0f);
    _outR.assign(maxBlock, 0.0f);
    _silence.assign(maxBlock, 0.0f);
    _meterDb = std::make_unique<std::atomic<float>[]>(engineChannels);
    for (int i = 0; i < engineChannels; ++i) _meterDb[i].store(-100.0f);

    try {
        _engine.prepare(sampleRate, maxBlock, engineChannels);
        for (int i = 0; i < engineChannels; ++i) {
            const auto p = app::profileFor(_classes[(size_t)i]);
            _engine.setChannelConfig(
                i,
                p.bus,
                p.isSpeech,
                app::safeGainDbFor(_classes[(size_t)i]),
                app::safePanFor(_classes[(size_t)i])
            );
        }

        _brain.configure(engineChannels, sampleRate, _classes);
        _brain.setScene(_scene);
        _brain.setOperatorBypass(_safeBypassAtomic.load());
        _brain.setFrozen(_frozenAtomic.load());
        _brain.setShadowMode(_shadowModeAtomic.load(std::memory_order_relaxed));
        _brain.setOnsetSource(&_engine);
        _brain.start();
        _brainStarted = true;
    } catch (const std::exception &ex) {
        [self fail:error message:[NSString stringWithFormat:@"Failed to prepare DSP engine: %s", ex.what()]];
        return NO;
    }

    return YES;
}

static bool writeFloatWav(const char *path, const float *samples, uint64_t frames, int channels, uint32_t sampleRate) {
    FILE *f = std::fopen(path, "wb");
    if (!f) return false;
    const uint16_t audioFormat = 3; // IEEE float
    const uint16_t bitsPerSample = 32;
    const uint16_t blockAlign = (uint16_t)(channels * sizeof(float));
    const uint32_t byteRate = sampleRate * blockAlign;
    const uint64_t dataBytes64 = frames * (uint64_t)blockAlign;
    const uint32_t dataBytes = (uint32_t)std::min<uint64_t>(dataBytes64, UINT32_MAX - 44);
    const uint32_t riffSize = 36 + dataBytes;

    std::fwrite("RIFF", 1, 4, f);
    std::fwrite(&riffSize, 4, 1, f);
    std::fwrite("WAVEfmt ", 1, 8, f);
    uint32_t fmtSize = 16;
    std::fwrite(&fmtSize, 4, 1, f);
    std::fwrite(&audioFormat, 2, 1, f);
    uint16_t channelCount = (uint16_t)channels;
    std::fwrite(&channelCount, 2, 1, f);
    std::fwrite(&sampleRate, 4, 1, f);
    std::fwrite(&byteRate, 4, 1, f);
    std::fwrite(&blockAlign, 2, 1, f);
    std::fwrite(&bitsPerSample, 2, 1, f);
    std::fwrite("data", 1, 4, f);
    std::fwrite(&dataBytes, 4, 1, f);
    std::fwrite(samples, 1, dataBytes, f);
    std::fclose(f);
    return true;
}

- (std::vector<app::Cls>)classesFromRoles:(NSArray<NSString *> *)roles count:(int)count {
    std::vector<app::Cls> classes((size_t)count, app::Cls::Unknown);
    for (int i = 0; i < count; ++i) {
        NSString *role = i < (int)roles.count ? roles[(NSUInteger)i] : @"unknown";
        classes[(size_t)i] = classForRole(role);
    }
    return classes;
}

static app::Cls classForRole(NSString *role) {
    NSString *r = role.lowercaseString;
    if ([r isEqualToString:@"speech"]) return app::Cls::Speech;
    if ([r isEqualToString:@"leadvocal"]) return app::Cls::LeadVocal;
    if ([r isEqualToString:@"bgv"]) return app::Cls::Bgv;
    if ([r isEqualToString:@"acousticguitar"]) return app::Cls::Acoustic;
    if ([r isEqualToString:@"electricguitar"]) return app::Cls::Electric;
    if ([r isEqualToString:@"bass"]) return app::Cls::Bass;
    if ([r isEqualToString:@"kick"]) return app::Cls::Kick;
    if ([r isEqualToString:@"keys"]) return app::Cls::Keys;
    return app::Cls::Unknown;
}

static app::Scene sceneForName(NSString *name) {
    NSString *scene = name.lowercaseString;
    if ([scene isEqualToString:@"preservice"]) return app::Scene::PreService;
    if ([scene isEqualToString:@"worship"]) return app::Scene::Worship;
    if ([scene isEqualToString:@"sermon"]) return app::Scene::Sermon;
    if ([scene isEqualToString:@"prayer"]) return app::Scene::Prayer;
    if ([scene isEqualToString:@"postservice"]) return app::Scene::PostService;
    return app::Scene::Worship;
}

static UInt32 framesInBufferList(const AudioBufferList *list) {
    if (!list) return 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        const AudioBuffer &buffer = list->mBuffers[b];
        if (!buffer.mData || buffer.mDataByteSize == 0 || buffer.mNumberChannels == 0) continue;
        return buffer.mDataByteSize / (buffer.mNumberChannels * (UInt32)sizeof(float));
    }
    return 0;
}

static void clearAudioBufferList(AudioBufferList *output) {
    if (!output) return;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
        AudioBuffer &buffer = output->mBuffers[b];
        if (!buffer.mData || buffer.mDataByteSize == 0) continue;
        std::memset(buffer.mData, 0, buffer.mDataByteSize);
    }
}

static void populateRawInputPointersFromBufferList(const AudioBufferList *input,
                                                   UInt32 frames,
                                                   int channelCount,
                                                   std::vector<std::vector<float>>& scratch,
                                                   std::vector<const float *>& rawInputPtrs,
                                                   const float *silence) {
    if (channelCount <= 0) return;
    for (int ch = 0; ch < channelCount; ++ch) {
        rawInputPtrs[(size_t)ch] = silence;
    }
    if (!input || frames == 0) return;

    int channelIndex = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers && channelIndex < channelCount; ++b) {
        const AudioBuffer &buffer = input->mBuffers[b];
        const UInt32 bufferChannels = buffer.mNumberChannels;
        if (bufferChannels == 0) continue;
        if (!buffer.mData || buffer.mDataByteSize == 0) {
            channelIndex += (int)std::min<UInt32>(bufferChannels, (UInt32)(channelCount - channelIndex));
            continue;
        }

        const UInt32 availableFrames = buffer.mDataByteSize / (bufferChannels * (UInt32)sizeof(float));
        if (availableFrames == 0) {
            channelIndex += (int)std::min<UInt32>(bufferChannels, (UInt32)(channelCount - channelIndex));
            continue;
        }
        const UInt32 framesToCopy = std::min<UInt32>(frames, availableFrames);
        const float *data = (const float *)buffer.mData;

        if (bufferChannels == 1 && availableFrames >= frames) {
            rawInputPtrs[(size_t)channelIndex++] = data;
            continue;
        }

        if (bufferChannels == 1) {
            float *dst = scratch[(size_t)channelIndex].data();
            std::memcpy(dst, data, sizeof(float) * framesToCopy);
            if (framesToCopy < frames) std::fill(dst + framesToCopy, dst + frames, 0.0f);
            rawInputPtrs[(size_t)channelIndex++] = dst;
            continue;
        }

        for (UInt32 local = 0; local < bufferChannels && channelIndex < channelCount; ++local) {
            float *dst = scratch[(size_t)channelIndex].data();
            for (UInt32 frame = 0; frame < framesToCopy; ++frame) {
                dst[frame] = data[(size_t)frame * bufferChannels + local];
            }
            if (framesToCopy < frames) std::fill(dst + framesToCopy, dst + frames, 0.0f);
            rawInputPtrs[(size_t)channelIndex++] = dst;
        }
    }
}

static bool isSimulatedDeviceUID(NSString *uid) {
    return [uid isEqualToString:AMSimulatedDeviceUID];
}

static bool isHD96TargetSampleRate(double sampleRate) {
    // Supported broadcast operating rates. The DSP runs at any rate; these are the
    // standard pro rates the bridge accepts as a safety net. The Swift start gate
    // additionally enforces the operator's exact expected rate (catching drift).
    return std::abs(sampleRate - 48000.0) < 1.0 || std::abs(sampleRate - 96000.0) < 1.0;
}

static bool isLivestreamSafeOutputRoute(NSString *inputName,
                                        NSString *inputUID,
                                        NSString *outputName,
                                        NSString *outputUID) {
    if (outputName.length == 0 && outputUID.length == 0) return false;

    NSString *inputRoute = [NSString stringWithFormat:@"%@ %@", inputName ?: @"", inputUID ?: @""];
    NSString *outputRoute = [NSString stringWithFormat:@"%@ %@", outputName ?: @"", outputUID ?: @""];

    if (containsAnyCaseInsensitive(outputRoute, @[AMSimulatedDeviceUID, @"simulated hd96 dante"])) {
        return true;
    }

    if (inputUID.length > 0 && [inputUID isEqualToString:outputUID]) {
        return containsStreamOutputKeyword(outputRoute) && !containsConsoleRouteKeyword(outputRoute);
    }

    if (containsConsoleRouteKeyword(outputRoute)) return false;
    if (containsStreamOutputKeyword(outputRoute)) return true;
    if (containsConsoleRouteKeyword(inputRoute)) return false;
    return false;
}

static bool containsStreamOutputKeyword(NSString *text) {
    return containsAnyCaseInsensitive(text, @[
        @"stream",
        @"encoder",
        @"broadcast",
        @"blackhole",
        @"loopback",
        @"obs",
        @"virtual",
        @"aggregate",
        @"restream",
        @"audio hijack",
        @"capture",
        @"cam link",
        @"atem",
        @"web presenter",
        @"decklink",
        @"ultrastudio",
        @"usb audio codec",
        @"zoom",
        @"teams",
        @"ndi"
    ]);
}

static bool containsConsoleRouteKeyword(NSString *text) {
    return containsAnyCaseInsensitive(text, @[
        @"dante",
        @"hd96",
        @"heritage",
        @"midas",
        @"console",
        @"foh"
    ]);
}

static bool containsAnyCaseInsensitive(NSString *text, NSArray<NSString *> *needles) {
    if (text.length == 0) return false;
    for (NSString *needle in needles) {
        if ([text rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return true;
        }
    }
    return false;
}

static NSString *fourCCString(UInt32 value) {
    char chars[5] = {
        (char)((value >> 24) & 0xff),
        (char)((value >> 16) & 0xff),
        (char)((value >> 8) & 0xff),
        (char)(value & 0xff),
        0
    };
    for (int i = 0; i < 4; ++i) {
        if (!std::isprint((unsigned char)chars[i])) {
            return [NSString stringWithFormat:@"0x%08x", (unsigned int)value];
        }
    }
    return [NSString stringWithFormat:@"'%s'", chars];
}

static NSString *audioFormatSummary(const AudioStreamBasicDescription& format) {
    return [NSString stringWithFormat:@"%@ flags=0x%08x bits=%u channels/frame=%u bytes/frame=%u",
            fourCCString(format.mFormatID),
            (unsigned int)format.mFormatFlags,
            (unsigned int)format.mBitsPerChannel,
            (unsigned int)format.mChannelsPerFrame,
            (unsigned int)format.mBytesPerFrame];
}

- (AudioDeviceID)deviceForUID:(NSString *)uid {
    for (AMDeviceInfo *info in [self availableDevices]) {
        if ([info.uid isEqualToString:uid]) {
            AudioObjectPropertyAddress address = {
                kAudioHardwarePropertyDevices,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            UInt32 dataSize = 0;
            if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &dataSize) != noErr) break;
            const UInt32 count = dataSize / sizeof(AudioDeviceID);
            std::vector<AudioDeviceID> devices(count);
            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &dataSize, devices.data()) != noErr) break;
            for (AudioDeviceID device : devices) {
                NSString *candidate = [self stringProperty:kAudioDevicePropertyDeviceUID forDevice:device fallback:@""];
                if ([candidate isEqualToString:uid]) return device;
            }
        }
    }
    return kAudioObjectUnknown;
}

- (AMDeviceInfo *)simulatedDeviceInfo {
    return [[AMDeviceInfo alloc] initWithUID:AMSimulatedDeviceUID
                                       name:@"Simulated HD96 Dante Split"
                              inputChannels:64
                             outputChannels:2
                                 sampleRate:96000.0
                         inputFormatSummary:AMSupportedFloat32FormatSummary
                        outputFormatSummary:AMSupportedFloat32FormatSummary
                       inputFormatSupported:YES
                      outputFormatSupported:YES];
}

- (AMDeviceInfo *)deviceInfoForDevice:(AudioDeviceID)device {
    if (device == kAudioObjectUnknown) return nil;
    NSString *uid = [self stringProperty:kAudioDevicePropertyDeviceUID forDevice:device fallback:@""];
    if (uid.length == 0) return nil;

    NSString *name = [self stringProperty:kAudioObjectPropertyName forDevice:device fallback:@"Unknown Device"];
    NSInteger inputs = [self channelCountForDevice:device scope:kAudioDevicePropertyScopeInput];
    NSInteger outputs = [self channelCountForDevice:device scope:kAudioDevicePropertyScopeOutput];
    double sampleRate = [self nominalSampleRateForDevice:device];
    NSString *inputFormatSummary = @"no input streams";
    NSString *outputFormatSummary = @"no output streams";
    const BOOL inputFormatSupported = inputs > 0
        ? [self streamFormatSupportedForDevice:device
                                         scope:kAudioDevicePropertyScopeInput
                               activeChannels:inputs
                                       summary:&inputFormatSummary]
        : NO;
    const BOOL outputFormatSupported = outputs > 0
        ? [self streamFormatSupportedForDevice:device
                                         scope:kAudioDevicePropertyScopeOutput
                               activeChannels:outputs
                                       summary:&outputFormatSummary]
        : NO;
    return [[AMDeviceInfo alloc] initWithUID:uid
                                       name:name
                              inputChannels:inputs
                             outputChannels:outputs
                                 sampleRate:sampleRate
                         inputFormatSummary:inputFormatSummary
                        outputFormatSummary:outputFormatSummary
                       inputFormatSupported:inputFormatSupported
                      outputFormatSupported:outputFormatSupported];
}

- (NSString *)stringProperty:(AudioObjectPropertySelector)selector forDevice:(AudioDeviceID)device fallback:(NSString *)fallback {
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef value = nullptr;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &value) != noErr || !value) return fallback;
    NSString *string = CFBridgingRelease(value);
    return string ?: fallback;
}

- (NSInteger)channelCountForDevice:(AudioDeviceID)device scope:(AudioObjectPropertyScope)scope {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        scope,
        kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &dataSize) != noErr || dataSize == 0) return 0;
    std::vector<uint8_t> storage(dataSize);
    AudioBufferList *list = (AudioBufferList *)storage.data();
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &dataSize, list) != noErr) return 0;
    NSInteger channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) channels += list->mBuffers[i].mNumberChannels;
    return channels;
}

- (double)nominalSampleRateForDevice:(AudioDeviceID)device {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 sampleRate = 0;
    UInt32 size = sizeof(sampleRate);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &sampleRate) != noErr) return 0;
    return sampleRate;
}

- (NSInteger)bufferFrameSizeForDevice:(AudioDeviceID)device {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 frames = 0;
    UInt32 size = sizeof(frames);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &frames) != noErr) return 0;
    return frames;
}

- (BOOL)streamFormatSupportedForDevice:(AudioDeviceID)device
                                  scope:(AudioObjectPropertyScope)scope
                        activeChannels:(NSInteger)activeChannels
                                summary:(NSString **)summary {
    if (activeChannels <= 0) {
        if (summary) *summary = @"no streams";
        return NO;
    }

    AudioObjectPropertyAddress streamsAddress = {
        kAudioDevicePropertyStreams,
        scope,
        kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nullptr, &dataSize);
    if (status != noErr || dataSize == 0) {
        if (summary) *summary = @"could not read streams";
        return NO;
    }

    const UInt32 streamCount = dataSize / sizeof(AudioStreamID);
    if (streamCount == 0) {
        if (summary) *summary = @"no streams";
        return NO;
    }

    std::vector<AudioStreamID> streams(streamCount);
    status = AudioObjectGetPropertyData(device, &streamsAddress, 0, nullptr, &dataSize, streams.data());
    if (status != noErr) {
        if (summary) *summary = @"could not read stream list";
        return NO;
    }

    BOOL allSupported = YES;
    NSMutableArray<NSString *> *formatSummaries = [NSMutableArray arrayWithCapacity:streamCount];
    for (AudioStreamID stream : streams) {
        AudioStreamBasicDescription format{};
        UInt32 formatSize = sizeof(format);
        AudioObjectPropertyAddress formatAddress = {
            kAudioStreamPropertyVirtualFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        status = AudioObjectGetPropertyData(stream, &formatAddress, 0, nullptr, &formatSize, &format);
        if (status != noErr) {
            if (summary) *summary = @"could not read stream format";
            return NO;
        }

        const BOOL supported = [AutoMixEngineBridge isSupportedCoreAudioPCMFormatID:format.mFormatID
                                                                             flags:format.mFormatFlags
                                                                    bitsPerChannel:format.mBitsPerChannel];
        allSupported = allSupported && supported;
        if (supported) {
            [formatSummaries addObject:[NSString stringWithFormat:@"%@ · %u ch/frame",
                                        AMSupportedFloat32FormatSummary,
                                        (unsigned int)format.mChannelsPerFrame]];
        } else {
            [formatSummaries addObject:audioFormatSummary(format)];
        }
    }

    if (summary) *summary = [formatSummaries componentsJoinedByString:@"; "];
    return allSupported;
}

- (BOOL)validateDeviceFloat32Format:(AudioDeviceID)device
                               scope:(AudioObjectPropertyScope)scope
                                role:(NSString *)role
                        errorMessage:(NSString **)errorMessage {
    AudioObjectPropertyAddress streamsAddress = {
        kAudioDevicePropertyStreams,
        scope,
        kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nullptr, &dataSize);
    if (status != noErr || dataSize == 0) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Could not read Core Audio %@ streams.", role];
        return NO;
    }

    const UInt32 streamCount = dataSize / sizeof(AudioStreamID);
    if (streamCount == 0) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Core Audio %@ device has no streams.", role];
        return NO;
    }

    std::vector<AudioStreamID> streams(streamCount);
    status = AudioObjectGetPropertyData(device, &streamsAddress, 0, nullptr, &dataSize, streams.data());
    if (status != noErr) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Could not read Core Audio %@ stream list.", role];
        return NO;
    }

    for (AudioStreamID stream : streams) {
        AudioStreamBasicDescription format{};
        UInt32 formatSize = sizeof(format);
        AudioObjectPropertyAddress formatAddress = {
            kAudioStreamPropertyVirtualFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        status = AudioObjectGetPropertyData(stream, &formatAddress, 0, nullptr, &formatSize, &format);
        if (status != noErr) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Could not read Core Audio %@ stream format.", role];
            return NO;
        }

        if (![AutoMixEngineBridge isSupportedCoreAudioPCMFormatID:format.mFormatID
                                                           flags:format.mFormatFlags
                                                  bitsPerChannel:format.mBitsPerChannel]) {
            if (errorMessage) {
                *errorMessage = [NSString stringWithFormat:@"Unsupported Core Audio %@ format: %@. Select a 32-bit little-endian float PCM device format for Dante/HD96.",
                                 role,
                                 audioFormatSummary(format)];
            }
            return NO;
        }
    }

    return YES;
}

- (void)fail:(NSError **)error message:(NSString *)message {
    [self setStatus:message];
    if (error) *error = [NSError errorWithDomain:AMBridgeErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
