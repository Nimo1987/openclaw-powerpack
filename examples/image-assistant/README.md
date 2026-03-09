# Image Assistant Example
 
Integrates image-prompt-writer + nano-banana-pro to generate e-commerce images from user requests.
 
## Usage

 ```bash
python3 workflow.py \
  --request "Bonne Mine 繁繆菪取, 作兀价原作量南克的小覆恓, �:16, 2■" \
  --resolution 2K
```

## Pipeline
 
1. LLM parses user request -> structured description
2. image-prompt-writer -> generates professional prompt
3. nano-banana-pro -> generates image
