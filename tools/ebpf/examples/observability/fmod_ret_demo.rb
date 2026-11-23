# E102 demo: fmod_ret on a security hook. Observe-only (returns the original
# verdict unchanged) so it is safe to run; proves BPF_MODIFY_RETURN attaches
# and fires.
#
# Overriding `ret` to a negative errno DOES deny the access — measured in E280
# (docs/experiments/E280_fmod_ret_deny_enforcement.md): returning -1 here makes
# the target process's open(2) fail with EPERM, selectively (other processes are
# untouched) and reversibly (detach restores it), with zero codegen changes.
# That is the same mechanism Tetragon uses for its `Override` action on
# security_* hooks. This demo stays observe-only on purpose: a deny policy can
# lock up the system depending on the match, so it lives in
# docs/experiments/results/E280/fmod_deny.rb rather than here.
@fired = 0
def fmod_ret__security_file_open(file, ret)
  @fired = @fired + 1
  ret
end
puts "[E102] fmod_ret/security_file_open attaching..."
sleep 3600
