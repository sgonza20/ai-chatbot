terraform { 
  cloud { 
    
    organization = "samlozano" 

    workspaces { 
      name = "test-workspace" 
    } 
  } 
}