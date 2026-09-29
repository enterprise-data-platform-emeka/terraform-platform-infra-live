import os
import subprocess
import tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    executable=Path(tmp)/'terraform'
    executable.write_text('''#!/bin/sh
if [ "$1 $2" = 'state list' ]; then
  [ "$SCENARIO" = error ] && exit 7
  [ "$SCENARIO" = runtime ] && printf 'module.data_lake.aws_s3_bucket.bronze\\nmodule.ingestion.aws_dms_replication_task.cdc\\n'
  exit 0
fi
printf '%s\\n' "$*" > "$CAPTURE"
''')
    executable.chmod(0o755)
    for case in ('error','empty','runtime'):
        capture=Path(tmp)/case
        env=dict(os.environ,PATH=tmp+':'+os.environ['PATH'],SCENARIO=case,CAPTURE=str(capture))
        result=subprocess.run(['make','destroy-safe','dev'],cwd=root,env=env,capture_output=True,text=True)
        if case=='error': assert result.returncode!=0 and not capture.exists()
        elif case=='empty': assert result.returncode==0 and not capture.exists()
        else:
            assert result.returncode==0
            assert capture.read_text().strip()=='destroy -target=module.ingestion -auto-approve -lock-timeout=5m'
print('3 teardown guard scenarios passed (Terraform mocked; no AWS actions).')
