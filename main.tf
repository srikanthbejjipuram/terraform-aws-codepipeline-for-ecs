# Terraform module which creates CodePipeline for ECS resources on AWS.
#
# https://docs.aws.amazon.com/codepipeline/latest/userguide/welcome.html

# https://www.terraform.io/docs/providers/aws/r/codepipeline.html
resource "aws_codepipeline" "default" {
  name     = "${var.name}"
  role_arn = "${aws_iam_role.default.arn}"

  # The Amazon S3 bucket where artifacts are stored for the pipeline.
  # https://docs.aws.amazon.com/codepipeline/latest/APIReference/API_ArtifactStore.html
  artifact_store {
    # You can specify the name of an S3 bucket but not a folder within the bucket.
    # A folder to contain the pipeline artifacts is created for you based on the name of the pipeline.
    # You can use any Amazon S3 bucket in the same AWS Region as the pipeline to store your pipeline artifacts.
    location = "${var.artifact_bucket_name}"

    # The value must be set to S3.
    type = "S3"

    # The encryption key used to encrypt the data in the artifact store, such as an AWS KMS key.
    # If this is undefined, the default key for Amazon S3 is used.
    encryption_key {
      # The ID used to identify the key. For an AWS KMS key, this is the key ID or key ARN.
      id = "${var.encryption_key_id != "" ? var.encryption_key_id : data.aws_kms_alias.s3.arn}"

      # The value must be set to KMS.
      type = "KMS"
    }
  }

  # The pipeline structure has the following requirements:
  #
  # - A pipeline must contain at least two stages.
  # - The first stage of a pipeline must contain at least one source action, and can only contain source actions.
  # - Only the first stage of a pipeline may contain source actions.
  # - At least one stage in each pipeline must contain an action that is not a source action.
  # - All stage names within a pipeline must be unique.
  #
  # https://docs.aws.amazon.com/codepipeline/latest/userguide/reference-pipeline-structure.html
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = 1
      run_order        = 1
      output_artifacts = ["Source"]

      configuration {
        Owner  = "${var.repository_owner}"
        Repo   = "${var.repository_name}"
        Branch = "${var.branch}"

        # The token require the following GitHub scopes:
        #
        # - The repo scope, which is used for full control to read and pull artifacts from public and private repositories into a pipeline.
        # - The admin:repo_hook scope, which is used for full control of repository hooks.
        #
        # Create a personal access token on your application settings page of GitHub.
        # https://help.github.com/articles/creating-a-personal-access-token-for-the-command-line/
        #
        # NOTE: github_oauth_token may show up in logs, and it will be stored in the raw state as plain-text.
        OAuthToken = "${var.github_oauth_token}"

        # Pipelines start automatically when repository changes are detected. One change detection method is
        # periodic checks. Periodic checks can be enabled or disabled using the PollForSourceChanges flag.
        # https://docs.aws.amazon.com/codepipeline/latest/userguide/run-automatically-polling.html
        PollForSourceChanges = "${var.poll_for_source_changes}"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = 1
      run_order        = 1
      input_artifacts  = ["Source"]
      output_artifacts = ["Build"]

      configuration {
        ProjectName = "${var.project_name}"

        # One of your input sources must be designated the PrimarySource. This source is the directory
        # where AWS CodeBuild looks for and runs your buildspec file. The keyword PrimarySource is used to
        # specify the primary source in the configuration section of the CodeBuild stage in the JSON file.
        # https://docs.aws.amazon.com/codebuild/latest/userguide/sample-pipeline-multi-input-output.html
        PrimarySource = "Source"
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = 1
      run_order       = 1
      input_artifacts = ["Build"]

      configuration {
        ClusterName = "${var.cluster_name}"
        ServiceName = "${var.service_name}"

        # An image definitions document is a JSON file that describes your ECS container name and the image and tag.
        # You must generate an image definitions file to provide the CodePipeline job worker
        # with the ECS container and image identification to use for your pipeline’s deployment stage.
        # https://docs.aws.amazon.com/codepipeline/latest/userguide/pipelines-create.html#pipelines-create-image-definitions
        FileName = "${var.file_name}"
      }
    }
  }

  # Suppress that Github OAuth causing persistent changes.
  # https://github.com/terraform-providers/terraform-provider-aws/issues/2854
  lifecycle {
    ignore_changes = [
      "stage.0.action.0.configuration.OAuthToken",
      "stage.0.action.0.configuration.%",
    ]
  }
}

data "aws_kms_alias" "s3" {
  name = "alias/aws/s3"
}

# CodePipeline Service Role
#
# https://docs.aws.amazon.com/codepipeline/latest/userguide/how-to-custom-role.html

# https://www.terraform.io/docs/providers/aws/r/iam_role.html
resource "aws_iam_role" "default" {
  name               = "${local.iam_name}"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
  path               = "${var.iam_path}"
  description        = "${var.description}"
  tags               = "${merge(map("Name", local.iam_name), var.tags)}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

# https://www.terraform.io/docs/providers/aws/r/iam_policy.html
resource "aws_iam_policy" "default" {
  name        = "${local.iam_name}"
  policy      = "${data.aws_iam_policy_document.policy.json}"
  path        = "${var.iam_path}"
  description = "${var.description}"
}

data "aws_iam_policy_document" "policy" {
  statement {
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
    ]

    resources = [
      "arn:aws:s3:::${var.artifact_bucket_name}",
      "arn:aws:s3:::${var.artifact_bucket_name}/*",
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "iam:PassRole",
    ]

    resources = ["*"]
  }
}

# https://www.terraform.io/docs/providers/aws/r/iam_role_policy_attachment.html
resource "aws_iam_role_policy_attachment" "default" {
  role       = "${aws_iam_role.default.name}"
  policy_arn = "${aws_iam_policy.default.arn}"
}

locals {
  iam_name = "${var.name}-codepipeline-for-ecs"
}
