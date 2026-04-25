import { Download, ChevronUp } from 'lucide-react';
import { useEffect, useState, useRef, useCallback } from 'react';
import { Button } from '@/components/ui/button';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Message, Parameter } from '@shared/types';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { ParameterInput } from '@/components/parameter/ParameterInput';
import { validateParameterValue } from '@/utils/parameterUtils';
import { useCurrentMessage } from '@/contexts/CurrentMessageContext';
import { downloadSTLFile, downloadOpenSCADFile } from '@/utils/downloadUtils';

interface ParameterSheetContentProps {
  parameters: Parameter[];
  onSubmit: (message: Message | null, parameters: Parameter[]) => void;
  currentOutput?: Blob;
}

export function ParameterSheetContent({
  parameters,
  onSubmit,
  currentOutput,
}: ParameterSheetContentProps) {
  const { currentMessage } = useCurrentMessage();
  const [selectedFormat, setSelectedFormat] = useState<'stl' | 'scad'>('stl');

  // Debounce timer for compilation
  const debounceTimerRef = useRef<NodeJS.Timeout | null>(null);
  const pendingParametersRef = useRef<Parameter[] | null>(null);

  // Cleanup debounce timer on unmount
  useEffect(() => {
    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, []);

  // Debounced submit function
  const debouncedSubmit = useCallback(
    (params: Parameter[]) => {
      // Store the parameters to submit
      pendingParametersRef.current = params;

      // Clear existing timer
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }

      // Set new debounced timer (300ms delay)
      debounceTimerRef.current = setTimeout(() => {
        if (pendingParametersRef.current) {
          onSubmit(currentMessage, pendingParametersRef.current);
          pendingParametersRef.current = null;
        }
      }, 200);
    },
    [onSubmit, currentMessage],
  );

  const handleCommit = (param: Parameter, value: Parameter['value']) => {
    // Validate the value before committing
    const validatedValue = validateParameterValue(param, value);

    // Update local state immediately for UI responsiveness
    const updatedParam = { ...param, value: validatedValue };
    const updatedParameters = parameters.map((p) =>
      p.name === param.name ? updatedParam : p,
    );

    // Debounce the actual OpenSCAD compilation
    debouncedSubmit(updatedParameters);
  };

  const handleDownload = () => {
    if (selectedFormat === 'stl') {
      handleDownloadSTL();
    } else {
      handleDownloadOpenSCAD();
    }
  };

  const handleDownloadSTL = () => {
    if (!currentOutput) return;
    downloadSTLFile(currentOutput, currentMessage);
  };

  const handleDownloadOpenSCAD = () => {
    if (!currentMessage?.content.artifact?.code) return;
    downloadOpenSCADFile(currentMessage.content.artifact.code, currentMessage);
  };

  const isDownloadDisabled =
    selectedFormat === 'stl'
      ? !currentOutput
      : !currentMessage?.content.artifact?.code;

  return (
    <>
      <ScrollArea className="h-full w-full px-4">
        <div className="flex flex-col gap-6 pb-4 pt-2">
          {parameters.map((param) => (
            <ParameterInput
              key={param.name}
              param={param}
              handleCommit={handleCommit}
            />
          ))}
        </div>
      </ScrollArea>
      <div className="flex w-full flex-col gap-4 p-4">
        <div className="flex border-t border-adam-neutral-700 pt-2">
          <Button
            onClick={handleDownload}
            disabled={isDownloadDisabled}
            aria-label={`download ${selectedFormat.toUpperCase()} file`}
            className="flex-1 rounded-r-none bg-adam-neutral-50 text-adam-neutral-800 hover:bg-adam-neutral-100 hover:text-adam-neutral-900"
          >
            <Download className="mr-2 h-4 w-4" />
            {selectedFormat.toUpperCase()}
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button
                disabled={
                  !currentOutput && !currentMessage?.content.artifact?.code
                }
                aria-label="select download format"
                className="rounded-l-none border-l border-adam-neutral-300 bg-adam-neutral-50 px-2 text-adam-neutral-800 hover:bg-adam-neutral-100 hover:text-adam-neutral-900"
              >
                <ChevronUp className="h-4 w-4" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem
                onClick={() => setSelectedFormat('stl')}
                disabled={!currentOutput}
                className="grid cursor-pointer grid-cols-3 text-adam-text-primary"
              >
                <span className="text-sm">.STL</span>
                <span className="col-span-2 text-xs text-adam-text-primary/60">
                  3D Printing
                </span>
              </DropdownMenuItem>
              <DropdownMenuItem
                onClick={() => setSelectedFormat('scad')}
                disabled={!currentMessage?.content.artifact?.code}
                className="grid cursor-pointer grid-cols-3 text-adam-text-primary"
              >
                <span className="text-sm">.SCAD</span>
                <span className="col-span-2 text-xs text-adam-text-primary/60">
                  OpenSCAD Code
                </span>
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>
    </>
  );
}
