-- run with it:
-- $ CUDA_VISIBLE_DEVICES=0 th eval_dcase.lua
-- The results will be written into "results.txt" file

require 'svm'
require 'audio'
require 'xlua'
require 'nn'
require 'cunn'
require 'cudnn'
require 'math'

-- Commandline Arguments
cmd = torch.CmdLine()
cmd:text()
cmd:text()
cmd:text('Evaluate Soundnet on DCASE2014')
cmd:text()
cmd:text('Options')
cmd:option('-net','models/soundnet8_final.t7','net name')
cmd:option('-layer',18,'layer')
cmd:option('-timewindow',5,'initial time window')
cmd:option('-outfile','results.txt','output filename')
cmd:text()
-- parse input params
params = cmd:parse(arg)


opt = {
  data_root = 'dcase/',
  train_set = 'dcase/train.txt',
  test_set = 'dcase/test.txt',
  sound_length = 30, -- secs
  net = params['net'],
  layer = params['layer'],
  time_segment = params['timewindow'],
  outfile = params['outfile']
}

net = torch.load(opt.net)
net:evaluate()
net:cuda()

print(net)
print('extracting layer ' .. opt.layer)

function read_dataset(file)
  print('reading ' .. file)
  local total = 0
  sample_count = 0
  local twindow_size = 0
  for line in io.lines(file) do total = total + 1 end
  local dataset,labels
  local counter = 1
  for line in io.lines(file) do 
    local split = {}
    for k in string.gmatch(line, "%S+") do table.insert(split, k) end

    local snd,sr = audio.load(opt.data_root .. '/' .. split[1])
    snd:mul(2^-22)

    net:forward(snd:view(1,1,-1,1):cuda())

    if opt.layer == 25 then
       feat = torch.cat(net.modules[opt.layer].output[1]:float():squeeze(),net.modules[opt.layer].output[2]:float():squeeze(),1)
    else
       feat = net.modules[opt.layer].output:float():squeeze()
    end

    if counter == 1 then
      twindow_size = torch.ceil((opt.time_segment/opt.sound_length)*feat:size(2));
      sample_count = feat:size(2) - twindow_size + 1
      dataset = torch.Tensor(total*sample_count, feat:size(1), twindow_size)
      print ('Time window size: ' .. twindow_size)
      labels = torch.Tensor(total*sample_count)
    end
    
    for i=1,sample_count do
       dataset[{ counter, {}, {} }]:copy(feat[{ {}, {i,i+twindow_size-1} }])
       labels[counter] = tonumber(split[2])
       counter = counter + 1
    end

    xlua.progress(counter, total*sample_count)
  end
  return {dataset,labels}
end

function convert_to_liblinear(dataset)
  local ds = {}
  for i=1,dataset[1]:size(1) do
    local label = dataset[2][i]
    local feat = dataset[1][i]:view(-1)
    local nz = feat:gt(0):nonzero()

    local val
    if nz:dim() > 0 then
      nz = nz:view(-1) 
      val = feat:index(1,nz)
    else
      nz = torch.Tensor{1}
      val = torch.Tensor{0}
    end

    table.insert(ds, {label, {nz:int(), val:float()}})
  end
  return ds
end


-- Feature Extranction & Data Preparation

train_data = read_dataset(opt.train_set)
test_data = read_dataset(opt.test_set)

train_data_ll = convert_to_liblinear(train_data)
test_data_ll = convert_to_liblinear(test_data)

-- SVM training

C = 0.01 

print('train')
model = liblinear.train(train_data_ll, '-c ' .. C .. ' -s 1 -B 1 ');

print('training accuracy:')
liblinear.predict(train_data_ll, model);

print('testing accuracy:')
dec,conf,vals = liblinear.predict(test_data_ll, model);

test_count = 0
for line in io.lines(opt.test_set) do test_count = test_count + 1 end

pred_labels = torch.Tensor(test_count);
gt = torch.Tensor(test_count)
for i=1,test_count do
  scores = torch.mean(vals[ {{(i-1)*sample_count+1,i*sample_count}}],1)
  max, ind = torch.max(scores,2)
  pred_labels[i] = ind 
  gt[i] = test_data[2][i*sample_count]+1
end

accuracy = torch.mean(torch.eq(gt,pred_labels):type('torch.DoubleTensor'))
print ('Accuracy:' .. accuracy)


-- Append results to file
file = io.open(opt.outfile, "a")
io.output(file)
io.write("Net: " .. opt.net .. "\t Layer: " .. opt.layer .. "\t TimeWindow: " .. opt.time_segment .. "\t Accuracy: " .. accuracy .. "\n")
io.close(file)
