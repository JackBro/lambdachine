#ifndef _CAPABILITY_H_
#define _CAPABILITY_H_

#include "common.hh"
#include "vm.hh"
#include "memorymanager.hh"
#include "jit.hh"

_START_LAMBDACHINE_NAMESPACE

#define FRAME_SIZE 3

typedef enum {
  kCall,
  kReturn
} BranchType;

class Capability {
public:
  explicit Capability(MemoryManager *mm);
  ~Capability();
  inline Thread *currentThread() { return currentThread_; }

  inline void enableBytecodeTracing() { flags_.set(kTraceBytecode); }
  inline bool isEnabledBytecodeTracing() const {
    return flags_.get(kTraceBytecode);
  }
  inline void enableDecodeClosures() { flags_.set(kDecodeClosures); }

  inline bool run() { return run(currentThread_); }
  // Eval given closure using current thread.
  bool eval(Thread *, Closure *);
  bool run(Thread *);
  inline Closure *staticRoots() const { return static_roots_; }
  inline bool isRecording() const {
    return flags_.get(kRecording);
  }
  inline Jit *jit() { return &jit_; }

  inline Word *traceExitHp() const { return traceExitHp_; }
  inline Word *traceExitHpLim() const { return traceExitHpLim_; }

  enum {
    STATE_INTERP,
    STATE_RECORD
  };

  // Sets interpreter state. Requires executing a SYNC instruction to
  // take effect.
  void setState(int state);

  inline int heapCheckFailQuick(char **heap, char **hplim);

private:
  typedef enum {
    kModeInit,
    kModeRun
  } InterpMode;

  typedef enum {
    kInterpOk = 0,
    kInterpOutOfSteps,
    kInterpStackOverflow,
    kInterpUnimplemented
  } InterpExitCode;

  typedef void *AsmFunction;

  InterpExitCode interpMsg(InterpMode mode);
  inline BcIns *interpBranch(BcIns *srcPc, BcIns *dstPc,
                             Word *&base,
                             BranchType branchType,
                             Thread *&T,
                             char *&heap, char *&heaplim,
                             const AsmFunction *&dispatch,
                             const AsmFunction *&dispatch2,
                             const AsmFunction *dispatch_debug,
                             const Code *&code);
  BcIns *interpBranch(BcIns *srcPc, BcIns *dst_pc, Word *base, BranchType);
  void finishRecording();

  MemoryManager *mm_;
  Thread *currentThread_;
  Closure *static_roots_;

  const AsmFunction *dispatch_;

  /* Pointers to the dispatch tables for various modes. */
  const AsmFunction *dispatch_normal_;
  const AsmFunction *dispatch_record_;
  const AsmFunction *dispatch_single_step_;
  BcIns *reload_state_pc_; // used by interpBranch

  HotCounters counters_;
  Jit jit_;

  static const int kTraceBytecode = 0;
  static const int kRecording     = 1;
  static const int kDecodeClosures = 2;
  Flags32 flags_;

  Word *traceExitHp_;
  Word *traceExitHpLim_;

  friend class Fragment;
  friend class BranchTargetBuffer;  // For resetting hot counters.
};

inline int
Capability::heapCheckFailQuick(char **heap, char **hplim)
{
  return mm_->bumpAllocatorFullNoGC(heap, hplim);
}

extern uint64_t recordings_started;
extern uint64_t switch_interp_to_asm;

_END_LAMBDACHINE_NAMESPACE

#endif /* _CAPABILITY_H_ */
