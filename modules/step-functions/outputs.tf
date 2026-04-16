output "state_machine_arn" {
  description = "ARN of the EDP pipeline Step Functions state machine. Pass to the session orchestrator to trigger and poll the pipeline."
  value       = aws_sfn_state_machine.pipeline.arn
}

output "state_machine_name" {
  description = "Name of the EDP pipeline Step Functions state machine."
  value       = aws_sfn_state_machine.pipeline.name
}
