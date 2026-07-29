#!/usr/bin/env node

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const vm = require('node:vm')

const workletPath = path.resolve(
  __dirname,
  '../web/public/worklets/loudness-processor.js',
)
const workletSource = fs.readFileSync(workletPath, 'utf8')
const sampleRate = 48_000
const blockSize = 128

function makeProcessor() {
  let Processor = null
  const messages = []
  class AudioWorkletProcessor {
    constructor() {
      this.port = {
        onmessage: null,
        postMessage(message) {
          messages.push(message)
        },
      }
    }
  }
  const context = vm.createContext({
    AudioWorkletProcessor,
    Float32Array,
    Math,
    registerProcessor(name, constructor) {
      assert.equal(name, 'loudness-processor')
      Processor = constructor
    },
    sampleRate,
  })
  vm.runInContext(workletSource, context, { filename: workletPath })
  assert.ok(Processor)
  return { processor: new Processor(), messages }
}

function render(generator, seconds = 2) {
  const { processor, messages } = makeProcessor()
  const totalFrames = sampleRate * seconds
  let frame = 0
  let maximumSample = 0

  while (frame < totalFrames) {
    const inputL = new Float32Array(blockSize)
    const inputR = new Float32Array(blockSize)
    const outputL = new Float32Array(blockSize)
    const outputR = new Float32Array(blockSize)
    for (let index = 0; index < blockSize && frame + index < totalFrames; index++) {
      const sample = generator(frame + index)
      inputL[index] = sample
      inputR[index] = sample
    }
    processor.process([[inputL, inputR]], [[outputL, outputR]])
    for (let index = 0; index < blockSize; index++) {
      maximumSample = Math.max(
        maximumSample,
        Math.abs(outputL[index]),
        Math.abs(outputR[index]),
      )
    }
    frame += blockSize
  }

  return {
    messages: messages.filter((message) => message.type === 'loudness'),
    maximumSample,
  }
}

test('look-ahead limiter keeps a sustained overload below the true-peak ceiling', () => {
  const result = render((frame) => (
    2.5 * Math.sin(2 * Math.PI * 997 * frame / sampleRate)
  ))
  const observed = result.messages.filter((message) => message.inputTruePeak > 0)
  assert.ok(observed.length > 10)
  assert.ok(Math.max(...observed.map((message) => message.truePeak)) <= -0.9)
  assert.ok(Math.min(...observed.map((message) => message.grDb)) < -6)
  assert.ok(result.maximumSample <= Math.pow(10, -1 / 20) + 1e-6)
})

test('look-ahead limiter contains isolated full-scale transients', () => {
  const result = render((frame) => (
    frame % 4_801 === 0 ? (frame % 9_602 === 0 ? 4 : -4) : 0
  ))
  const observed = result.messages.filter((message) => message.inputTruePeak > 0)
  assert.ok(observed.length > 0)
  assert.ok(Math.max(...observed.map((message) => message.truePeak)) <= -0.9)
  assert.ok(Math.min(...observed.map((message) => message.grDb)) < -6)
  assert.ok(result.maximumSample <= Math.pow(10, -1 / 20) + 1e-6)
})

test('sub-ceiling material passes without limiter reduction', () => {
  const result = render((frame) => (
    0.25 * Math.sin(2 * Math.PI * 997 * frame / sampleRate)
  ))
  const observed = result.messages.filter((message) => message.truePeak > -90)
  assert.ok(observed.length > 10)
  assert.ok(Math.min(...observed.map((message) => message.grDb)) > -0.05)
  assert.ok(Math.max(...observed.map((message) => message.truePeak)) < -10)
})
