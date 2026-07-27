#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMDeviceInfo : NSObject
@property (nonatomic, copy, readonly) NSString *uid;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) NSInteger inputChannels;
@property (nonatomic, readonly) NSInteger outputChannels;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, copy, readonly) NSString *inputFormatSummary;
@property (nonatomic, copy, readonly) NSString *outputFormatSummary;
@property (nonatomic, readonly) BOOL inputFormatSupported;
@property (nonatomic, readonly) BOOL outputFormatSupported;
- (instancetype)initWithUID:(NSString *)uid
                      name:(NSString *)name
             inputChannels:(NSInteger)inputChannels
            outputChannels:(NSInteger)outputChannels
                sampleRate:(double)sampleRate;
- (instancetype)initWithUID:(NSString *)uid
                      name:(NSString *)name
             inputChannels:(NSInteger)inputChannels
            outputChannels:(NSInteger)outputChannels
                sampleRate:(double)sampleRate
        inputFormatSummary:(NSString *)inputFormatSummary
       outputFormatSummary:(NSString *)outputFormatSummary
      inputFormatSupported:(BOOL)inputFormatSupported
     outputFormatSupported:(BOOL)outputFormatSupported;
@end

typedef NS_OPTIONS(NSUInteger, AMChannelOverrideMask) {
    AMChannelOverrideMaskTrim = 1u << 0,
    AMChannelOverrideMaskHPF = 1u << 1,
    AMChannelOverrideMaskGate = 1u << 2,
    AMChannelOverrideMaskEQ = 1u << 3,
    AMChannelOverrideMaskCompressor = 1u << 4,
    AMChannelOverrideMaskFader = 1u << 5,
    AMChannelOverrideMaskPan = 1u << 6,
    AMChannelOverrideMaskReverb = 1u << 7,
};

// Complete control-rate channel override payload. EQ arrays contain eight entries in
// this fixed order: corrective 1/2, masking 1/2, voicing 1/2/3, de-esser.
@interface AMChannelProcessingOverride : NSObject
@property (nonatomic) AMChannelOverrideMask overrideMask;
@property (nonatomic) double trimDb;
@property (nonatomic) double hpfHz;
@property (nonatomic) BOOL gateEnabled;
@property (nonatomic) double gateThresholdDb;
@property (nonatomic) double gateRatio;
@property (nonatomic) double gateRangeDb;
@property (nonatomic, copy) NSArray<NSString *> *eqTypes;
@property (nonatomic, copy) NSArray<NSNumber *> *eqFrequenciesHz;
@property (nonatomic, copy) NSArray<NSNumber *> *eqQs;
@property (nonatomic, copy) NSArray<NSNumber *> *eqGainsDb;
@property (nonatomic) double compressorThresholdDb;
@property (nonatomic) double compressorRatio;
@property (nonatomic) double compressorAttackSeconds;
@property (nonatomic) double compressorReleaseSeconds;
@property (nonatomic) double compressorKneeDb;
@property (nonatomic) double compressorMakeupDb;
@property (nonatomic) double faderDb;
@property (nonatomic) double pan;
@property (nonatomic) double reverbSendDb;
@end

@interface AutoMixEngineBridge : NSObject
@property (nonatomic, copy, readonly) NSString *status;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, readonly) BOOL recordingSaveInProgress;
@property (nonatomic, readonly) NSUInteger recordedFrameCount;
@property (nonatomic, readonly) NSUInteger recordingTargetFrameCount;
@property (nonatomic, readonly) BOOL continuousRecording;
@property (nonatomic, readonly) NSUInteger continuousRecordingFrameCount;
@property (nonatomic, readonly) NSUInteger continuousRecordingDroppedFrameCount;
@property (nonatomic, readonly) NSUInteger continuousRecordingSegmentCount;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) NSInteger inputChannelCount;
@property (nonatomic, readonly) NSInteger bufferFrameSize;
@property (nonatomic, readonly) NSInteger algorithmicLatencyFrames;
@property (nonatomic, readonly) double algorithmicLatencyMs;
@property (nonatomic, readonly) double estimatedOneWayLatencyMs;
@property (nonatomic, readonly) NSInteger inputHardwareLatencyFrames;
@property (nonatomic, readonly) NSInteger outputHardwareLatencyFrames;
@property (nonatomic, readonly) NSInteger separateOutputPrebufferFrames;
@property (nonatomic, readonly) NSInteger separateOutputRingFillFrames;
@property (nonatomic, readonly) double outputClockCorrectionPpm;
@property (nonatomic, readonly) double inputCallbackAgeMs;
@property (nonatomic, readonly) double outputCallbackAgeMs;
@property (nonatomic, readonly) NSUInteger dropoutCount;
@property (nonatomic, readonly) NSUInteger callbackOverrunCount;
@property (nonatomic, readonly) NSUInteger renderDeadlineMissCount;
@property (nonatomic, readonly) NSUInteger outputUnderrunCount;
@property (nonatomic, readonly) NSUInteger outputOverrunCount;
@property (nonatomic, readonly) BOOL watchdogSafeActive;
@property (nonatomic, readonly) NSInteger lastCallbackFrameCount;
@property (nonatomic, readonly) NSInteger maxObservedCallbackFrameCount;
@property (nonatomic, readonly) double momentaryLufs;
@property (nonatomic, readonly) double shortTermLufs;
@property (nonatomic, readonly) double integratedLufs;
@property (nonatomic, readonly) double limiterGainReductionDb;
@property (nonatomic, readonly) double currentBpm;
@property (nonatomic, readonly) double currentBpmConfidence;
@property (nonatomic, readonly) double autoLoudnessTrimDb;
@property (nonatomic, readonly) BOOL shadowModeEnabled;
- (double)autoTrimDbForChannel:(NSInteger)channel;
- (double)autoFaderDbForChannel:(NSInteger)channel;
- (double)learnedNoiseFloorDbForChannel:(NSInteger)channel;
- (BOOL)autoChannelActiveForChannel:(NSInteger)channel;

+ (BOOL)isSupportedCoreAudioPCMFormatID:(uint32_t)formatID
                                  flags:(uint32_t)formatFlags
                         bitsPerChannel:(uint32_t)bitsPerChannel;
+ (BOOL)isHD96TargetSampleRate:(double)sampleRate;
+ (BOOL)isLivestreamSafeOutputRouteForInputName:(NSString *)inputName
                                       inputUID:(NSString *)inputUID
                                     outputName:(NSString *)outputName
                                      outputUID:(NSString *)outputUID;
#if DEBUG
+ (NSArray<NSArray<NSNumber *> *> *)debugExtractFloat32InputChannelsFromBuffers:(NSArray<NSArray<NSNumber *> *> *)buffers
                                                                   channelCounts:(NSArray<NSNumber *> *)channelCounts
                                                                expectedChannels:(NSInteger)expectedChannels
                                                                          frames:(NSInteger)frames;
- (NSUInteger)debugRunRealtimeNoAllocationProbeWithFrameCount:(NSUInteger)frameCount
                                                        blocks:(NSUInteger)blocks;
- (NSUInteger)debugRunRealtimeCoreAudioInputNoAllocationProbeWithFrameCount:(NSUInteger)frameCount
                                                                      blocks:(NSUInteger)blocks
                                                           channelsPerBuffer:(NSUInteger)channelsPerBuffer;
- (NSArray<NSArray<NSNumber *> *> *)debugRenderCoreAudioMonoOutputBuffersWithFrameCount:(NSUInteger)frameCount
                                                                      outputBufferCount:(NSUInteger)outputBufferCount;
- (NSArray<NSArray<NSNumber *> *> *)debugRenderCoreAudioInterleavedOutputChannelsWithFrameCount:(NSUInteger)frameCount
                                                                             outputChannelCount:(NSUInteger)outputChannelCount;
- (NSArray<NSArray<NSNumber *> *> *)debugRenderCoreAudioMonoOutputBuffersWithFrameCount:(NSUInteger)frameCount
                                                                      outputBufferCount:(NSUInteger)outputBufferCount
                                                                     activeInputChannel:(NSInteger)activeInputChannel
                                                                           warmupBlocks:(NSUInteger)warmupBlocks;
- (NSArray<NSNumber *> *)debugRenderCoreAudioInputLevelsWithFrameCount:(NSUInteger)frameCount
                                                    activeInputChannel:(NSInteger)activeInputChannel;
- (NSArray<NSArray<NSNumber *> *> *)debugRenderSeparateCoreAudioInterleavedOutputChannelsWithFrameCount:(NSUInteger)frameCount
                                                                                      outputChannelCount:(NSUInteger)outputChannelCount
                                                                                            warmupBlocks:(NSUInteger)warmupBlocks;
- (NSArray<NSNumber *> *)debugCaptureRecordingFirstInputFrameWithFrameCount:(NSUInteger)frameCount
                                                          channelsPerBuffer:(NSUInteger)channelsPerBuffer;
- (void)debugSetBrainTickPausedForWatchdogProbe:(BOOL)paused;
#endif
- (NSArray<AMDeviceInfo *> *)availableDevices;
- (nullable AMDeviceInfo *)runningInputDeviceInfo;
- (nullable AMDeviceInfo *)runningOutputDeviceInfo;
- (BOOL)startWithInputDeviceUID:(NSString *)uid
                outputDeviceUID:(NSString *)outputUID
                   channelRoles:(NSArray<NSString *> *)roles
             inputChannelIndices:(NSArray<NSNumber *> *)inputChannelIndices
                          error:(NSError * _Nullable * _Nullable)error;
// Rehearsal/monitor start: relaxes the broadcast go-live gates (96 kHz requirement and
// strict output isolation) so an operator can verify signal flow during a rehearsal.
// Technical requirements (float format, matched in/out clock, an output that is not the
// Dante input itself) are still enforced. NOT for live broadcast.
- (BOOL)startWithInputDeviceUID:(NSString *)uid
                outputDeviceUID:(NSString *)outputUID
                   channelRoles:(NSArray<NSString *> *)roles
             inputChannelIndices:(NSArray<NSNumber *> *)inputChannelIndices
                      rehearsal:(BOOL)rehearsal
                          error:(NSError * _Nullable * _Nullable)error;
- (BOOL)startSimulatedWithChannelCount:(NSInteger)channelCount
                            sampleRate:(double)sampleRate
                       bufferFrameSize:(NSInteger)bufferFrameSize
                           channelRoles:(NSArray<NSString *> *)roles
                    inputChannelIndices:(NSArray<NSNumber *> *)inputChannelIndices
                                  error:(NSError * _Nullable * _Nullable)error;
- (BOOL)startSimulatedSeparateOutputWithChannelCount:(NSInteger)channelCount
                                         sampleRate:(double)sampleRate
                              inputBufferFrameSize:(NSInteger)inputBufferFrameSize
                             outputBufferFrameSize:(NSInteger)outputBufferFrameSize
                                      channelRoles:(NSArray<NSString *> *)roles
                               inputChannelIndices:(NSArray<NSNumber *> *)inputChannelIndices
                                             error:(NSError * _Nullable * _Nullable)error;
- (void)stop;
- (void)setSafeBypass:(BOOL)enabled;
- (void)setFrozen:(BOOL)enabled;
- (void)setShadowMode:(BOOL)enabled;
- (void)setSceneName:(NSString *)sceneName;
- (BOOL)setChannelRoleForChannel:(NSInteger)channel
                             role:(NSString *)role;
- (BOOL)setInputChannelIndex:(NSInteger)inputChannelIndex
             forMixerChannel:(NSInteger)mixerChannel;
- (BOOL)setStereoLinkForLeftChannel:(NSInteger)leftChannel
                       rightChannel:(NSInteger)rightChannel;
- (BOOL)clearStereoLinkForChannel:(NSInteger)channel;
- (BOOL)setManualMixOverrideForChannel:(NSInteger)channel
                               faderDb:(double)faderDb
                                    pan:(double)pan
                          overrideFader:(BOOL)overrideFader
                            overridePan:(BOOL)overridePan;
- (BOOL)setManualChannelProcessingOverride:(AMChannelProcessingOverride *)settings
                                forChannel:(NSInteger)channel
    NS_SWIFT_NAME(setManualChannelProcessing(_:forChannel:));
- (BOOL)clearManualMixOverrideForChannel:(NSInteger)channel;
- (NSArray<NSNumber *> *)inputLevelsDb;
- (NSArray<NSNumber *> *)outputLevelsDb;
- (BOOL)startTestRecordingAtURL:(NSURL *)url
                        seconds:(double)seconds
                          error:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)consumeFinishedRecordingURL;
- (BOOL)startContinuousRecordingAtDirectoryURL:(NSURL *)directoryURL
                                          error:(NSError * _Nullable * _Nullable)error;
- (void)stopContinuousRecording;
#if DEBUG
- (void)debugSetContinuousRecordingSegmentFrameLimit:(NSUInteger)frames;
#endif
@end

NS_ASSUME_NONNULL_END
