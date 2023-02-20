resource "aws_key_pair" "ssh_key" {
  key_name   = var.ssh_key_name
  public_key = file(var.ssh_key_path)
}

resource "aws_vpc" "k8s_vpc" {
  cidr_block = var.vpc_cidr_block
}

resource "aws_subnet" "k8s_subnet_1" {
  vpc_id     = aws_vpc.k8s_vpc.id
  cidr_block = var.subnet_cidr_blocks[0]
  availability_zone = var.availability_zones[0]
}

resource "aws_subnet" "k8s_subnet_2" {
  vpc_id     = aws_vpc.k8s_vpc.id
  cidr_block = var.subnet_cidr_blocks[1]
  availability_zone = var.availability_zones[1]
}

resource "aws_subnet" "k8s_subnet_3" {
  vpc_id     = aws_vpc.k8s_vpc.id
  cidr_block = var.subnet_cidr_blocks[2]
  availability_zone = var.availability_zones[2]
}

resource "aws_security_group" "k8s_sg" {
  name_prefix = "k8s_sg"
  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 6443
    to_port   = 6443
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "k8s_master" {
  ami           = var.ami
  instance_type = var.instance_type
  key_name      = aws_key_pair.ssh_key.key_name
  subnet_id     = aws_subnet.k8s_subnet_1.id
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  associate_public_ip_address = true
  user_data     = <<-EOF
                  #!/bin/bash
                  echo "Environment=production" >> /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

                  # Install Docker
                  apt-get update && apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
                  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
                  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                  apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
                  systemctl enable docker

                  # Install kubeadm, kubelet, and kubectl
                  apt-get update && apt-get install -y apt-transport-https ca-certificates curl
                  curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
                  echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
                  apt-get update && apt-get install -y kubelet kubeadm kubectl
                  apt-mark hold kubelet kubeadm kubectl

                  # Initialize the Kubernetes control plane
                  kubeadm init --pod-network-cidr=10.244.0.0/16
                  mkdir -p $HOME/.kube
                  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
                  sudo chown $(id -u):$(id -g) $HOME/.kube/config

                  # Install Flannel network add-on
                  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
                
                  # Save the join command to a Terraform output variable
                  kubeadm token create --print-join-command > /tmp/kubeadm_join_command
                  chmod +x /tmp/kubeadm_join_command
                  echo "kubeadm join command:"
                  cat /tmp/kubeadm_join_command                 
                 EOF
  tags = {
    Name = "k8s-master"
  }
}
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for kubelet to start...'",
      "until sudo systemctl status kubelet | grep 'Active: active (running)' ; do sleep 1 ; done",
      "echo 'Kubelet started!'"
    ]
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    host        = self.public_ip
  }
}

output "kubeadm_join_command" {
  value = "${aws_instance.k8s_master.user_data_file}"
}
resource "aws_instance" "k8s_worker_1" {
  ami           = var.ami
  instance_type = var.instance_type
  key_name      = aws_key_pair.ssh_key.key_name
  subnet_id     = aws_subnet.k8s_subnet_2.id
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  associate_public_ip_address = true
  user_data     = <<-EOF
                  #!/bin/bash
                  echo "Environment=production" >> /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
                  # Install Docker
                  apt-get update && apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
                  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
                  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                  apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
                  systemctl enable docker

                  # Install kubeadm, kubelet, and kubectl
                  apt-get update && apt-get install -y apt-transport-https ca-certificates curl
                  curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
                  echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
                  apt-get update && apt-get install -y kubelet kubeadm kubectl
                  apt-mark hold kubelet kubeadm kubectl
                  
                  # Join the Kubernetes cluster using the kubeadm join command from the master node
                  ${var.kubeadm_join_command}                  
                  EOF
  tags = {
    Name = "k8s-worker-1"
  }
}
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for kubelet to start...'",
      "until sudo systemctl status kubelet | grep 'Active: active (running)' ; do sleep 1 ; done",
      "echo 'Kubelet started!'"
    ]
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    host        = self.public_ip
  }
}

resource "aws_instance" "k8s_worker_2" {
  ami           = var.ami
  instance_type = var.instance_type
  key_name      = aws_key_pair.ssh_key.key_name
  subnet_id     = aws_subnet.k8s_subnet_3.id
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  associate_public_ip_address = true
  user_data     = <<-EOF
                  #!/bin/bash
                  echo "Environment=production" >> /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
                  # Install Docker
                  apt-get update && apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
                  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
                  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                  apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
                  systemctl enable docker

                  # Install kubeadm, kubelet, and kubectl
                  apt-get update && apt-get install -y apt-transport-https ca-certificates curl
                  curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
                  echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
                  apt-get update && apt-get install -y kubelet kubeadm kubectl
                  apt-mark hold kubelet kubeadm kubectl
                  
                  # Join the Kubernetes cluster using the kubeadm join command from the master node
                  ${var.kubeadm_join_command}         
                  EOF
  tags = {
    Name = "k8s-worker-2"
  }
}
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for kubelet to start...'",
      "until sudo systemctl status kubelet | grep 'Active: active (running)' ; do sleep 1 ; done",
      "echo 'Kubelet started!'"
    ]
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    host        = self.public_ip
  }
}
