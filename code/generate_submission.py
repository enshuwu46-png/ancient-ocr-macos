from __future__ import annotations
import argparse,json,math
from pathlib import Path
import torch, torch.nn as nn
from PIL import Image
from torchvision import models, transforms
from ultralytics import YOLO
from tqdm import tqdm
Image.MAX_IMAGE_PIXELS=None

def build_recognizer(path,device):
    ckpt=torch.load(path,map_location='cpu',weights_only=False); labels=ckpt['labels']
    model=models.efficientnet_b0(weights=None); model.classifier[1]=nn.Linear(model.classifier[1].in_features,len(labels))
    model.load_state_dict(ckpt['model']); model.to(device).eval()
    tf=transforms.Compose([transforms.Resize((224,224)),transforms.ToTensor(),transforms.Normalize((0.485,0.456,0.406),(0.229,0.224,0.225))])
    return model,labels,tf

def expand_box(box,w,h,r):
    x1,y1,x2,y2=box; bw,bh=x2-x1,y2-y1
    return max(0,int(math.floor(x1-bw*r))),max(0,int(math.floor(y1-bh*r))),min(w,int(math.ceil(x2+bw*r))),min(h,int(math.ceil(y2+bh*r)))

@torch.no_grad()
def classify(model,labels,tf,crops,device,batch_size):
    out=[]
    for s in range(0,len(crops),batch_size):
        x=torch.stack([tf(c) for c in crops[s:s+batch_size]]).to(device)
        with torch.autocast(device_type='cuda',dtype=torch.float16): logits=model(x)
        out.extend(labels[i] for i in logits.argmax(1).cpu().tolist())
    return out

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--detector',type=Path,required=True); ap.add_argument('--recognizer',type=Path,required=True)
    ap.add_argument('--images',type=Path,required=True); ap.add_argument('--output',type=Path,required=True); ap.add_argument('--imgsz',type=int,default=1280)
    ap.add_argument('--conf',type=float,default=0.15); ap.add_argument('--iou',type=float,default=0.6); ap.add_argument('--padding',type=float,default=0.10); ap.add_argument('--batch-size',type=int,default=256)
    args=ap.parse_args(); device=torch.device('cuda'); detector=YOLO(str(args.detector)); rec,labels,tf=build_recognizer(args.recognizer,device)
    paths=sorted([p for p in args.images.iterdir() if p.suffix.lower() in {'.png','.jpg','.jpeg','.tif','.tiff'}]); pred={}
    for path in tqdm(paths,desc='生成提交'):
        with Image.open(path) as im: image=im.convert('RGB')
        w,h=image.size; result=detector.predict(source=image,imgsz=args.imgsz,conf=args.conf,iou=args.iou,device=0,verbose=False)[0]
        boxes=[] if result.boxes is None else [tuple(map(float,b)) for b in result.boxes.xyxy.cpu().tolist()]
        crops=[image.crop(expand_box(b,w,h,args.padding)) for b in boxes]
        texts=classify(rec,labels,tf,crops,device,args.batch_size) if crops else []
        pred[path.stem]=[{'bbox':[int(round(x1)),int(round(y1)),int(round(x2-x1)),int(round(y2-y1))],'text':t} for (x1,y1,x2,y2),t in zip(boxes,texts)]
    args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(json.dumps(pred,ensure_ascii=False,indent=2),encoding='utf-8'); print('图片数:',len(paths)); print('保存到:',args.output)

if __name__=='__main__': main()
