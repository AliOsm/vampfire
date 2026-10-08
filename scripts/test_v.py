"""Build and run the application-level V security tests under resource_guard."""
from build import compile_v
from toolchain import ROOT, run

compile_v(ROOT / 'src/security_test.v', ROOT / '.build/security_test', release=False)
run([ROOT / '.build/security_test'])
print('V application checks passed: cryptography, network policy, rich text, notification targeting, and database transaction/statement lifetimes.')
