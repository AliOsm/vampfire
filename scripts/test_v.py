"""Build and run the application-level V security tests under resource_guard."""
from build import compile_v
from toolchain import ROOT, run

compile_v(ROOT / 'src/security_test.v', ROOT / '.build/security_test', release=False)
run([ROOT / '.build/security_test'])
print('Five V security checks passed: RFC 8291 ciphertext, P-256 signature encoding, network policy, rich-text fragments, notification targeting/session cleanup.')
