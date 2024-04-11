# Scripts for working with development VM

```bash
./ami-build.sh --ami-name "id-dev-vm-$(date +%s)"
env REGION=eu-north-1 AMI_NAME_FILTER='id-dev-vm-*' ./run.sh id-dev-vm
env REGION=eu-north-1 ./terminate.sh id-dev-vm
```
