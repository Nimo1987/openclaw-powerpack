#!/usr/bin/env python3
"""
Image Assistant Workflow
触发词：做张图、帮我画、生成图片、做个图
描述：接收用户需求，自动生成电商图
调用：python3 workflow.py --request "用户需求" --resolution 2K

Example:
    python3 workflow.py --request "赛博朋克风格的猫，霓虹灯背景" --resolution 2K
"""

import argparse
import sys
import os
from datetime import datetime

# Add lib to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'workflow-engine', 'lib'))

from skill_runner import run_skill, run_llm_raw


def parse_args():
    parser = argparse.ArgumentParser(description='Generate images from user requests')
    parser.add_argument('--request', required=True, help='User image generation request')
    parser.add_argument('--ref-image', default='', help='Optional reference image path')
    parser.add_argument('--resolution', default='2K', choices=['1K', '2K', '4K'], 
                       help='Image resolution')
    return parser.parse_args()


def generate_filename():
    """Generate timestamp-based filename"""
    timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    return f"{timestamp}-generated.png"


def main():
    args = parse_args()
    
    print(f"🎨 Image Assistant Workflow")
    print(f"Request: {args.request}")
    print(f"Resolution: {args.resolution}")
    print("-" * 40)
    
    # Step 1: Parse user request with LLM
    print("\n📋 Step 1: Parsing user request...")
    system_prompt = """You are an image requirement analyst. Parse the user's image generation request into a structured description.
Output a structured natural language description including: subject, scene, style, color palette, composition, lighting, atmosphere.
Output only the description, no other content."""
    
    description = run_llm_raw(system_prompt, args.request)
    print(f"✅ Parsed: {description[:100]}...")
    
    # Step 2: Generate professional prompt
    print("\n✨ Step 2: Generating professional prompt...")
    prompt_data = {
        "user_request": description,
        "reference_image": args.ref_image
    }
    prompt = run_skill("image-prompt-writer", prompt_data)
    print(f"✅ Prompt: {prompt[:100]}...")
    
    # Step 3: Generate image
    print("\n🖼️  Step 3: Generating image...")
    filename = generate_filename()
    output_path = os.path.join(os.path.dirname(__file__), 'output', filename)
    
    # Ensure output directory exists
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    image_data = {
        "prompt": prompt,
        "filename": output_path,
        "resolution": args.resolution
    }
    
    if args.ref_image:
        image_data["input_images"] = [args.ref_image]
    
    result = run_skill("nano-banana-pro", image_data)
    print(f"✅ Image saved: {result}")
    
    print("\n✨ Workflow completed!")
    return result


if __name__ == "__main__":
    main()
