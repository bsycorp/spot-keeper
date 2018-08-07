# Spot Keeper

This is a simple set of scripts to enable the use of EC2 Spot Blocks in addition to On-Demand EC2 instances for limited duration, non-reschedulable workloads, like CI builds. 

Regular spot instances are a bad fit for CI builds where generally if a CI job is rescheduled it is marked as failed and fails the build, so regular EC2 spot instances even with 2 minute warnings will cause unacceptable build failures when the spot instance is preempted. Spot blocks aim to solve this problem by giving you a defined duration that the instance will remain available, they are cheaper than on-demand (but not as cheap as proper spots of course).

The way Spot Keeper works is it creates instances from a template ASG, this ASG is normally used to create on-demand instances to meet CI job workloads via Kubernetes Autoscaler. These on-demand instances are expensive however, so substituting them with Spot Blocks will save some money. By using this ASG as the template, we get instances that look like on-demand CI build nodes, but are actually Spot Blocks. An added benefit is when our Spot block instances aren't renewed or are over capacity the on-demand ASG will kick in to meet the un-met demand.

So Spot Keeper's job is like a ghetto Spot Block ASG, it is running all the time as a pod in Kubernetes and is configured with a template ASG, a desired instance count and operating hours. It will aim to create the nominated number of instances within the operating hours and renew expiring Spot Blocks as they get close to their defined duration. It also manages gracefully removing these instances from the cluster as they near their expiry, so build jobs don't fail when the instance is terminated (done via `kubectl cordon`).

## IAM Permissions

IAM permissions are required to create, terminate, describe etc, these are suitable permissions to run spot-keeper.

```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:Describe*",
                "autoscaling:Describe*",
                "ec2:RequestSpotInstances",
                "ec2:CancelSpotInstanceRequests",
                "ec2:RunInstances",
                "ec2:TerminateInstances",
                "ec2:CreateTags",
                "iam:List*",
                "iam:PassRole"
            ],
            "Resource": [
                "*"
            ]
        }
    ]
}
```

## Kubernetes manifest

Example in `kubernetes.yml`