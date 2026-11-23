require_relative '../../scripts/lib/capture-selection'
rows=[['positive','a.rb','a','a'],['negative','b.rb','b','b']]
raise 'default changed' unless CaptureSelection.select(rows,nil)==rows
raise 'selection' unless CaptureSelection.select(rows,'b')==[rows[1]]
['','c','b,b'].each do |bad|
  begin;CaptureSelection.select(rows,bad);raise 'accepted invalid selection';rescue ArgumentError;end
end
record={'derived_content'=>'source'}
raise 'observed success' unless CaptureSelection.outcome('negative',record,0,true)=='positive'
raise 'observed refusal' unless CaptureSelection.outcome('negative',record,1,true)=='negative'
[2,nil].each do |rc|
  begin;CaptureSelection.outcome('negative',record,rc,true);raise 'accepted abnormal rc';rescue ArgumentError;end
end
begin;CaptureSelection.outcome('negative',{},0,true);raise 'observed native';rescue ArgumentError;end
raise 'default negative' unless CaptureSelection.outcome('negative',record,0,false)=='negative'
puts 'PASS capture subset and observed derived outcomes'
