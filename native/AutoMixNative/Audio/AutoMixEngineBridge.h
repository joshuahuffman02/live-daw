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

@interface AutoMixEngineBridge : NSObject
@property (nonatomic, copy, readonly) NSString *status;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, readonly) BOOL recordingSaveInProgress;
@property (nonatomic, readonly) NSUInteger recordedFrameCount;
@property (nonatomic, readonly) NSUInteger recordingTargetFrameCount;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) NSInteger inputChannelCount;
@property (nonatomic, readonly) NSInteger bufferFrameSize;
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
- (void)setSceneName:(NSString *)sceneName;
- (BOOL)setChannelRoleForChannel:(NSInteger)channel
                             role:(NSString *)role;
- (BOOL)setInputChannelIndex:(NSInteger)inputChannelIndex
             forMixerChannel:(NSInteger)mixerChannel;
- (BOOL)setManualMixOverrideForChannel:(NSInteger)channel
                               faderDb:(double)faderDb
                                    pan:(double)pan
                          overrideFader:(BOOL)overrideFader
                            overridePan:(BOOL)overridePan;
- (BOOL)clearManualMixOverrideForChannel:(NSInteger)channel;
- (NSArray<NSNumber *> *)inputLevelsDb;
- (NSArray<NSNumber *> *)outputLevelsDb;
- (BOOL)startTestRecordingAtURL:(NSURL *)url
                        seconds:(double)seconds
                          error:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)consumeFinishedRecordingURL;
@end

NS_ASSUME_NONNULL_END
