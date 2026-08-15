export type TrackId = 'ambient' | 'focus' | 'rain' | 'lofi'

export type TrackInfo = {
  id: TrackId
  title: string
  description: string
}

export const TRACKS: TrackInfo[] = [
  {
    id: 'ambient',
    title: 'ambient',
    description: 'Soft pads for long reads',
  },
  {
    id: 'focus',
    title: 'focus',
    description: 'Gentle pulse, low distraction',
  },
  {
    id: 'rain',
    title: 'rain',
    description: 'Filtered noise bed',
  },
  {
    id: 'lofi',
    title: 'lofi',
    description: 'Warm chord loop',
  },
]

type Voice = {
  stop: () => void
}

class MusicPlayer {
  private ctx: AudioContext | null = null
  private master: GainNode | null = null
  private voice: Voice | null = null
  private current: TrackId | null = null
  private volume = 0.35
  private paused = false

  list(): string[] {
    return TRACKS.map((t) => `  ${t.id.padEnd(8)} ${t.description}`)
  }

  status(): string {
    if (!this.current) return 'Music: stopped'
    if (this.paused) return `Music: paused (${this.current}) ♪`
    return `Music: playing ${this.current} ♫  vol ${Math.round(this.volume * 100)}%`
  }

  async play(track?: string): Promise<string> {
    const id = (track?.toLowerCase() || this.current || 'ambient') as TrackId
    if (!TRACKS.some((t) => t.id === id)) {
      return `Error: unknown track "${track}". Try: music list`
    }

    await this.ensureCtx()
    if (!this.ctx || !this.master) return 'Error: audio unavailable'

    if (this.ctx.state === 'suspended') {
      await this.ctx.resume()
    }

    this.stopVoice()
    this.current = id
    this.paused = false
    this.voice = this.startTrack(id)
    return `Playing ${id} ♫`
  }

  pause(): string {
    if (!this.current || !this.ctx) return 'Music: nothing playing'
    if (this.paused) return 'Music: already paused'
    void this.ctx.suspend()
    this.paused = true
    return `Paused ${this.current} ♪`
  }

  resume(): string {
    if (!this.current || !this.ctx) return 'Music: nothing to resume'
    void this.ctx.resume()
    this.paused = false
    return `Resumed ${this.current} ♫`
  }

  stop(): string {
    this.stopVoice()
    const was = this.current
    this.current = null
    this.paused = false
    return was ? `Stopped ${was}` : 'Music: already stopped'
  }

  setVolume(raw: string): string {
    const n = Number(raw)
    if (!Number.isFinite(n) || n < 0 || n > 100) {
      return 'Usage: music volume <0-100>'
    }
    this.volume = n / 100
    if (this.master) this.master.gain.value = this.volume
    return `Volume ${n}%`
  }

  private async ensureCtx() {
    if (this.ctx) return
    const Ctx =
      window.AudioContext ||
      (window as unknown as { webkitAudioContext: typeof AudioContext })
        .webkitAudioContext
    if (!Ctx) return
    this.ctx = new Ctx()
    this.master = this.ctx.createGain()
    this.master.gain.value = this.volume
    this.master.connect(this.ctx.destination)
  }

  private stopVoice() {
    this.voice?.stop()
    this.voice = null
  }

  private startTrack(id: TrackId): Voice {
    const ctx = this.ctx!
    const master = this.master!
    const stops: Array<() => void> = []

    switch (id) {
      case 'ambient': {
        const freqs = [110, 164.81, 196, 246.94]
        for (const f of freqs) {
          const osc = ctx.createOscillator()
          const gain = ctx.createGain()
          osc.type = 'sine'
          osc.frequency.value = f
          gain.gain.value = 0.045
          osc.connect(gain)
          gain.connect(master)
          osc.start()
          stops.push(() => {
            osc.stop()
          })
        }
        break
      }
      case 'focus': {
        const osc = ctx.createOscillator()
        const lfo = ctx.createOscillator()
        const lfoGain = ctx.createGain()
        const gain = ctx.createGain()
        osc.type = 'triangle'
        osc.frequency.value = 174.61
        lfo.frequency.value = 0.12
        lfoGain.gain.value = 0.03
        gain.gain.value = 0.05
        lfo.connect(lfoGain)
        lfoGain.connect(gain.gain)
        osc.connect(gain)
        gain.connect(master)
        osc.start()
        lfo.start()
        stops.push(() => {
          osc.stop()
          lfo.stop()
        })
        break
      }
      case 'rain': {
        const bufferSize = 2 * ctx.sampleRate
        const buffer = ctx.createBuffer(1, bufferSize, ctx.sampleRate)
        const data = buffer.getChannelData(0)
        for (let i = 0; i < bufferSize; i++) data[i] = Math.random() * 2 - 1
        const noise = ctx.createBufferSource()
        noise.buffer = buffer
        noise.loop = true
        const filter = ctx.createBiquadFilter()
        filter.type = 'lowpass'
        filter.frequency.value = 900
        const gain = ctx.createGain()
        gain.gain.value = 0.08
        noise.connect(filter)
        filter.connect(gain)
        gain.connect(master)
        noise.start()
        stops.push(() => {
          noise.stop()
        })
        break
      }
      case 'lofi': {
        const notes = [130.81, 164.81, 196.0, 261.63]
        let step = 0
        const gain = ctx.createGain()
        gain.gain.value = 0.06
        gain.connect(master)

        const tick = () => {
          const osc = ctx.createOscillator()
          const env = ctx.createGain()
          osc.type = 'sine'
          osc.frequency.value = notes[step % notes.length]
          env.gain.value = 0
          osc.connect(env)
          env.connect(gain)
          const now = ctx.currentTime
          env.gain.linearRampToValueAtTime(0.7, now + 0.02)
          env.gain.exponentialRampToValueAtTime(0.001, now + 0.9)
          osc.start(now)
          osc.stop(now + 1)
          step += 1
        }
        tick()
        const timer = window.setInterval(tick, 700)
        stops.push(() => window.clearInterval(timer))
        break
      }
    }

    return {
      stop: () => {
        for (const s of stops) s()
      },
    }
  }
}

export const musicPlayer = new MusicPlayer()
